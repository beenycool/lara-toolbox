//
//  httpserver.swift
//  lara
//
//  Minimal HTTP/1.1 control API for the Memory Lab, built on Network.framework
//  the same way ftpserver.swift is: singleton ObservableObject, one serial
//  queue, no locks, every @Published update forwarded to the main queue.
//
//  The point of this server is that nobody has to tap the phone: the Memory
//  Lab's per-process memory dump (mem_dump_process) and quick strings scan
//  (mem_quick_strings) can be driven from another machine on the same Wi-Fi.
//
//  Read-only by design: /regions, /dump and /strings only READ another
//  process's memory through the kernel r/w primitive. There is no write
//  endpoint, mem_write_user is never called, and no path in this file writes
//  to the device filesystem outside lara's own Documents/lara_dumps.
//
//  Endpoints (every one requires the token):
//    GET    /status                          readiness, app version, server info
//    GET    /procs                           mem_procs()
//    GET    /regions?pid=N&preset=0&large=0  mem_regions()
//    POST   /dump     pid,preset,large,cap   async job -> mem_dump_process
//    POST   /strings  pid,keyword,large,cap  async job -> mem_quick_strings
//    GET    /jobs                            recent jobs
//    GET    /jobs/<id>                       one job: state, progress, log, result
//    DELETE /jobs/<id>                       request cancellation
//    GET    /dirs  (alias /dumps)            folders in Documents/lara_dumps
//
//  Auth: "Authorization: Bearer <token>" or "X-Auth: <token>". The token is
//  the httptoken preference; on first use it is seeded from the FTP password
//  when one exists, otherwise a random token is generated. The server refuses
//  to start without one.
//

import Foundation
import Network
import Combine

// MARK: - jobs

/// One asynchronous memory operation. All fields may only be touched on the
/// server's serial queue (the C engine talks to it through progress/logger
/// blocks that hop back onto that queue). The one exception is the cancel
/// pointer, whose single byte is flipped by the queue and polled by the engine.
final class httpjob {
    let id: String
    let kind: String            // "dump" | "strings"
    let pid: pid_t
    let preset: Int
    let includeLarge: Bool
    let cap: UInt64
    let keyword: String
    let started = Date()

    var state = "queued"        // queued | running | done | failed | cancelled
    var progress: Double = 0
    var completed: Double = -1  // last progress value published to the UI
    var lines: [String] = []
    var result: [String: Any] = [:]
    var ended: Date?
    var cancel = false
    var cancelpointer: UnsafeMutablePointer<ObjCBool>?

    init(id: String, kind: String, pid: pid_t, preset: Int, includeLarge: Bool, cap: UInt64, keyword: String) {
        self.id = id
        self.kind = kind
        self.pid = pid
        self.preset = preset
        self.includeLarge = includeLarge
        self.cap = cap
        self.keyword = keyword
    }

    /// Small dictionary for /jobs and /status.
    func summary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "kind": kind,
            "pid": Int(pid),
            "state": state,
            "progress": progress,
            "started": started.timeIntervalSince1970
        ]
        if kind == "dump" {
            dict["preset"] = preset
        } else {
            dict["keyword"] = keyword
        }
        dict["large"] = includeLarge
        dict["cap"] = cap
        if let ended = ended {
            dict["ended"] = ended.timeIntervalSince1970
            dict["elapsed"] = ended.timeIntervalSince(started)
        }
        for key in ["ok", "partial", "cancelled", "path", "folder", "stringsPath",
                    "written", "scanned", "bytes", "regions", "planned", "estimated", "error"] {
            if let value = result[key] {
                dict[key] = value
            }
        }
        if let error = dict["error"] as? String, error.isEmpty {
            dict.removeValue(forKey: "error")
        }
        return dict
    }

    /// summary() plus the job's log ring buffer.
    func detail() -> [String: Any] {
        var dict = summary()
        dict["log"] = lines
        dict["log_lines"] = lines.count
        return dict
    }
}

// MARK: - request

private struct httprequest {
    let method: String
    let target: String
    let path: String
    let querystring: String
    let params: [String: String]
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    func param(_ name: String) -> String? {
        params[name.lowercased()]
    }

    func int(_ name: String) -> Int? {
        guard let value = param(name) else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    func bool(_ name: String, default fallback: Bool) -> Bool {
        guard let value = param(name)?.lowercased() else { return fallback }
        return ["1", "true", "yes", "on", "y"].contains(value)
    }
}

private enum httprequeststate {
    case incomplete
    case invalid(Int, String)
    case ready(httprequest)
}

private final class httpconversation {
    let connection: NWConnection
    let remote: String
    let created = Date()
    var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
        self.remote = String(describing: connection.endpoint)
    }
}

// MARK: - server

final class httpserver: ObservableObject {
    static let shared = httpserver()

    static let defaultport: Int = 8383

    @Published private(set) var isrunning = false
    @Published private(set) var status = "stopped"
    @Published private(set) var boundport: UInt16 = UInt16(httpserver.defaultport)
    @Published private(set) var logs: [String] = []
    @Published private(set) var joblist: [[String: Any]] = []
    @Published private(set) var jobline = ""
    @Published private(set) var requestcount = 0

    private let queue = DispatchQueue(label: "lara.httpserver")
    private let jobqueue = DispatchQueue(label: "lara.httpserver.jobs", qos: .userInitiated)

    private static let loglimit = 400
    private static let joblinelimit = 500
    private static let maxheaderbytes = 16 * 1024
    private static let maxbodybytes = 256 * 1024
    private static let maxconnections = 16
    private static let maxactivejobs = 8
    private static let keepjobs = 24
    private static let requesttimeout: TimeInterval = 20
    static let capmax: UInt64 = 512 * 1024 * 1024

    private static let timeformatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: httpconversation] = [:]
    private var jobs: [String: httpjob] = [:]
    private var joborder: [String] = []
    private var lastjobid: String?
    private var startedat = Date()
    private var userstopped = false
    private var ftpstarted = false
    private var token = ""

    deinit {
        listener?.cancel()
        for conversation in connections.values {
            conversation.connection.cancel()
        }
    }

    // MARK: preferences

    /// Creates random tokens for the UI. 12 characters minimum, ambiguous
    /// characters removed, same alphabet as the FTP password generator.
    static func generatetoken(length: Int = 24) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var result = ""
        for _ in 0..<max(12, length) {
            let index = Int(arc4random_uniform(UInt32(alphabet.count)))
            result.append(alphabet[index])
        }
        return result
    }

    /// The token used for auth. Stored in "httptoken"; the first time it is
    /// needed it is seeded from the FTP password so one secret covers both
    /// servers, otherwise a fresh random token is generated and persisted.
    func resolvedtoken() -> String {
        let defaults = UserDefaults.standard
        let stored = (defaults.string(forKey: "httptoken") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
            return stored
        }
        let ftppassword = (defaults.string(forKey: "ftppassword") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fresh = ftppassword.isEmpty ? httpserver.generatetoken() : ftppassword
        defaults.set(fresh, forKey: "httptoken")
        return fresh
    }

    func tokenisfromftp() -> Bool {
        let defaults = UserDefaults.standard
        let stored = (defaults.string(forKey: "httptoken") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ftppassword = (defaults.string(forKey: "ftppassword") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !stored.isEmpty && !ftppassword.isEmpty && stored == ftppassword
    }

    /// The port from preferences ("httpport"), clamped to a usable high port.
    func preferredport() -> UInt16 {
        let stored = UserDefaults.standard.integer(forKey: "httpport")
        let raw = stored <= 0 ? httpserver.defaultport : stored
        let clamped = min(65535, max(1024, raw))
        return UInt16(clamped)
    }

    // MARK: lifecycle

    /// Mirrors ftpserver.start(): validation here, the actual listener work on
    /// the serial queue. Refuses to start without a token.
    @discardableResult
    func start(port: UInt16) -> Bool {
        guard port > 0, let nwport = NWEndpoint.Port(rawValue: port) else {
            log("invalid port \(port)")
            return false
        }
        let resolved = resolvedtoken()
        guard !resolved.isEmpty else {
            log("refusing to start: no token is configured")
            return false
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.userstopped = false
            self.startlistener(port: port, nwport: nwport, token: resolved)
        }
        return true
    }

    /// Starts the listener if the user has not disabled auto-start and has not
    /// explicitly stopped the server this session. Safe to call often: the app
    /// calls it at launch, when the exploit becomes ready and when the app
    /// comes back to the foreground.
    func autostart() {
        startftpifwanted()

        guard !userstopped else { return }
        let enabled = UserDefaults.standard.object(forKey: "httpenabled") as? Bool ?? true
        guard enabled else { return }

        queue.async { [weak self] in
            guard let self else { return }
            guard self.listener == nil else { return }
            let port = self.preferredport()
            guard let nwport = NWEndpoint.Port(rawValue: port) else { return }
            let resolved = self.resolvedtoken()
            guard !resolved.isEmpty else {
                self.log("auto-start refused: no token is configured")
                return
            }
            self.startlistener(port: port, nwport: nwport, token: resolved)
        }
    }

    /// Must run on the serial queue.
    private func startlistener(port: UInt16, nwport: NWEndpoint.Port, token: String) {
        guard listener == nil else {
            log("server is already running")
            return
        }

        self.token = token

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Same scoping as the FTP server: the API is reachable over Wi-Fi, not
        // over cellular/VPN interfaces.
        parameters.requiredInterfaceType = .wifi

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwport)
        } catch {
            log("failed to create listener on port \(port): \(error.localizedDescription)")
            publish { server in
                server.isrunning = false
                server.status = "failed: \(error.localizedDescription)"
            }
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.newConnectionLimit = 64
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                self.startedat = Date()
                self.log("listening on port \(port)")
                self.publish { server in
                    server.isrunning = true
                    server.boundport = port
                    server.status = "listening on port \(port)"
                }
            case .waiting(let error):
                self.log("listener waiting: \(error.localizedDescription)")
                self.publish { server in
                    server.status = "waiting: \(error.localizedDescription)"
                }
            case .failed(let error):
                self.log("listener failed: \(error.localizedDescription)")
                self.listener = nil
                listener.cancel()
                self.publish { server in
                    server.isrunning = false
                    server.status = "failed: \(error.localizedDescription)"
                }
            case .cancelled:
                self.publish { server in
                    server.isrunning = false
                }
            default:
                break
            }
        }

        self.listener = listener
        self.boundport = port
        listener.start(queue: queue)
        log("starting HTTP control server on port \(port)")
        publish { server in
            server.isrunning = true
            server.boundport = port
            server.status = "starting on port \(port)"
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.userstopped = true
            for conversation in self.connections.values {
                conversation.connection.cancel()
            }
            self.connections.removeAll()
            if let listener = self.listener {
                self.listener = nil
                listener.cancel()
            }
            self.log("server stopped")
            self.publish { server in
                server.isrunning = false
                server.status = "stopped"
            }
        }
    }

    func clearlogs() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }

    // MARK: optional coexistence with the FTP server
    //
    // Off by default ("httpstartftp"). When on, the API brings the FTP server
    // up with the stored credentials so a fresh launch needs no taps at all
    // and the full-disk fallback is available too. The FTP code is untouched;
    // this only calls ftpserver.start() with the same preferences FTPView uses.
    private func startftpifwanted() {
        guard !ftpstarted else { return }
        guard UserDefaults.standard.bool(forKey: "httpstartftp") else { return }

        queue.async { [weak self] in
            guard let self, !self.ftpstarted else { return }
            let defaults = UserDefaults.standard
            let password = (defaults.string(forKey: "ftppassword") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let allowanonymous = defaults.object(forKey: "ftpallowanonymous") as? Bool ?? false
            guard !password.isEmpty || allowanonymous else {
                self.log("not starting FTP: no password stored and anonymous login is off")
                return
            }
            self.ftpstarted = true
            let stored = defaults.integer(forKey: "ftpport")
            let rawport = stored <= 0 ? 2121 : stored
            let port = UInt16(min(65535, max(1, rawport)))
            let username = (defaults.string(forKey: "ftpusername") ?? "lara")
            let startinmobile = defaults.object(forKey: "ftpstartinmobile") as? Bool ?? true
            let readonly = defaults.object(forKey: "ftpreadonly") as? Bool ?? false
            ftpserver.shared.start(port: port,
                                   startpath: startinmobile ? "/var/mobile" : "/",
                                   username: username,
                                   password: password,
                                   allowanonymous: allowanonymous,
                                   readonly: readonly)
            self.log("asked the FTP server to start alongside the API (httpstartftp, port \(port))")
        }
    }

    /// Cancels a queued or running job (same code path as DELETE /jobs/<id>).
    func cancel(jobid: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let job = self.jobs[jobid] else { return }
            self.requestcancel(job)
        }
    }

    // MARK: logging

    func log(_ message: String) {
        DispatchQueue.main.async {
            let stamp = httpserver.timeformatter.string(from: Date())
            self.logs.append("\(stamp) \(message)")
            if self.logs.count > httpserver.loglimit {
                self.logs.removeFirst(self.logs.count - httpserver.loglimit)
            }
        }
        globallogger.log("(http) \(message)")
    }

    private func publish(_ update: @escaping (httpserver) -> Void) {
        DispatchQueue.main.async {
            update(self)
        }
    }

    private func publishjobs() {
        let snapshot = joborder.suffix(8).reversed().compactMap { id -> [String: Any]? in
            guard let job = jobs[id] else { return nil }
            return job.summary()
        }
        publish { server in
            server.joblist = Array(snapshot)
        }
    }

    private func publishjobline(_ line: String) {
        publish { server in
            server.jobline = line
        }
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        guard connections.count < httpserver.maxconnections else {
            log("rejecting connection from \(String(describing: connection.endpoint)): too many open connections")
            connection.cancel()
            return
        }

        let conversation = httpconversation(connection: connection)
        connections[ObjectIdentifier(connection)] = conversation

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, let conversation = self.connections[ObjectIdentifier(connection)] else { return }
            switch state {
            case .ready:
                self.log("client connected: \(conversation.remote)")
                self.receive(conversation)
            case .failed(let error):
                self.log("connection failed: \(error.localizedDescription)")
                self.teardown(conversation)
            case .cancelled:
                self.teardown(conversation)
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + httpserver.requesttimeout) { [weak self] in
            guard let self, let conversation = self.connections[ObjectIdentifier(connection)] else { return }
            self.log("dropping \(conversation.remote): request did not complete in \(Int(httpserver.requesttimeout))s")
            self.teardown(conversation)
        }
    }

    private func teardown(_ conversation: httpconversation) {
        let key = ObjectIdentifier(conversation.connection)
        guard connections[key] != nil else { return }
        connections.removeValue(forKey: key)
        conversation.connection.stateUpdateHandler = nil
        conversation.connection.cancel()
    }

    private func receive(_ conversation: httpconversation) {
        conversation.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, iscomplete, error in
            guard let self, self.connections[ObjectIdentifier(conversation.connection)] != nil else { return }

            if let data, !data.isEmpty {
                conversation.buffer.append(data)
                if conversation.buffer.count > httpserver.maxheaderbytes + httpserver.maxbodybytes {
                    self.log("request from \(conversation.remote) exceeded \(httpserver.maxheaderbytes + httpserver.maxbodybytes) bytes")
                    self.respond(conversation, 413, ["ok": false, "error": "request too large"])
                    return
                }
            }

            switch self.parserequest(conversation) {
            case .ready(let request):
                self.handle(request, on: conversation)
                return
            case .invalid(let code, let message):
                self.log("rejecting request from \(conversation.remote): \(message)")
                self.respond(conversation, code, ["ok": false, "error": message])
                return
            case .incomplete:
                break
            }

            if error != nil || iscomplete {
                self.teardown(conversation)
                return
            }
            self.receive(conversation)
        }
    }

    private func parserequest(_ conversation: httpconversation) -> httprequeststate {
        let buffer = conversation.buffer
        guard let headerend = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > httpserver.maxheaderbytes {
                return .invalid(431, "request header too large")
            }
            return .incomplete
        }

        let headerdata = buffer[buffer.startIndex..<headerend.lowerBound]
        let head = String(decoding: headerdata, as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let requestline = lines.first, !requestline.isEmpty else {
            return .invalid(400, "missing request line")
        }
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if headers[key] == nil {
                headers[key] = value
            }
        }

        let parts = requestline.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else {
            return .invalid(400, "malformed request line")
        }
        let method = parts[0].uppercased()
        let target = parts[1]

        if (headers["transfer-encoding"] ?? "").lowercased().contains("chunked") {
            return .invalid(411, "chunked request bodies are not supported")
        }
        let declared = headers["content-length"].flatMap { Int($0) } ?? 0
        if declared < 0 {
            return .invalid(400, "invalid content-length")
        }
        if declared > httpserver.maxbodybytes {
            return .invalid(413, "request body too large (limit \(httpserver.maxbodybytes) bytes)")
        }

        let bodystart = headerend.upperBound
        let available = buffer.distance(from: bodystart, to: buffer.endIndex)
        guard available >= declared else {
            return .incomplete
        }
        let body = declared > 0 ? Data(buffer[bodystart..<buffer.index(bodystart, offsetBy: declared)]) : Data()

        var params = httpserver.queryparams(target)
        if !body.isEmpty {
            let ctype = (headers["content-type"] ?? "").lowercased()
            if ctype.contains("json"), let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                for (key, value) in object {
                    if let bool = value as? Bool {
                        params[key.lowercased()] = bool ? "1" : "0"
                    } else if let number = value as? NSNumber {
                        params[key.lowercased()] = number.stringValue
                    } else if let string = value as? String {
                        params[key.lowercased()] = string
                    }
                }
            } else {
                let text = String(decoding: body, as: UTF8.self)
                for (key, value) in httpserver.formparams(text) {
                    params[key] = value
                }
            }
        }

        let path: String
        let querystring: String
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            querystring = String(target[target.index(after: mark)...])
        } else {
            path = target
            querystring = ""
        }

        return .ready(httprequest(method: method, target: target, path: path,
                                  querystring: querystring, params: params,
                                  headers: headers, body: body))
    }

    private static func queryparams(_ target: String) -> [String: String] {
        guard let mark = target.firstIndex(of: "?") else { return [:] }
        return formparams(String(target[target.index(after: mark)...]))
    }

    private static func formparams(_ text: String) -> [String: String] {
        var params: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            if let equals = pair.firstIndex(of: "=") {
                let key = httpserver.decode(String(pair[..<equals]))
                let value = httpserver.decode(String(pair[pair.index(after: equals)...]))
                params[key.lowercased()] = value
            } else {
                params[httpserver.decode(String(pair)).lowercased()] = ""
            }
        }
        return params
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }

    // MARK: request handling

    private func handle(_ request: httprequest, on conversation: httpconversation) {
        let started = Date()
        let code = route(request, on: conversation)
        requestcount += 1
        let elapsed = Date().timeIntervalSince(started) * 1000
        let querystring = request.querystring.isEmpty ? "" : "?\(request.querystring)"
        log("C> \(request.method) \(request.path)\(querystring) -> \(code) (\(String(format: "%.1f", elapsed)) ms)")
    }

    private func route(_ request: httprequest, on conversation: httpconversation) -> Int {
        let path = normalizepath(request.path)

        // The index is public so a browser/curl mistake says what to do.
        if path.isEmpty || path == "index" || path == "help" {
            return respond(conversation, 200, indexpayload())
        }

        guard authorized(request) else {
            log("unauthorized \(request.method) \(path) from \(conversation.remote)")
            return respond(conversation, 401, [
                "ok": false,
                "error": "missing or invalid token: send Authorization: Bearer <token> or X-Auth: <token>"
            ], headers: ["WWW-Authenticate": "Bearer"])
        }

        switch (request.method, path) {
        case ("GET", "status"):
            return respond(conversation, 200, statuspayload())

        case ("GET", "procs"), ("POST", "procs"):
            return handleprocs(conversation)

        case ("GET", "regions"), ("POST", "regions"):
            return handleregions(request, conversation)

        case ("POST", "dump"), ("POST", "dumps"):
            return enqueuejob(request, kind: "dump", conversation: conversation)

        case ("POST", "strings"):
            return enqueuejob(request, kind: "strings", conversation: conversation)

        case ("POST", "exploit"):
            return handlestart(request, conversation: conversation, kind: "exploit")

        case ("POST", "sandbox"):
            return handlestart(request, conversation: conversation, kind: "sandbox")

        case ("GET", "jobs"):
            return respond(conversation, 200, [
                "ok": true,
                "jobs": joborder.reversed().compactMap { id -> [String: Any]? in
                    jobs[id]?.summary()
                }
            ])

        case ("GET", "dirs"), ("GET", "dumps"):
            return handledirs(conversation)

        default:
            // /jobs/<id>
            if path.hasPrefix("jobs/"), !path.hasPrefix("jobs//") {
                let id = String(path.dropFirst("jobs/".count))
                return handlejob(id: id, request: request, conversation: conversation)
            }
            if ["procs", "regions", "dump", "dumps", "strings", "jobs", "dirs", "status", "exploit", "sandbox"].contains(path) {
                return respond(conversation, 405, ["ok": false, "error": "\(request.method) is not supported for /\(path)"],
                               headers: ["Allow": ["dump", "dumps", "strings", "exploit", "sandbox"].contains(path) ? "POST" : "GET"])
            }
            return respond(conversation, 404, ["ok": false, "error": "unknown path /\(path)"])
        }
    }

    private func authorized(_ request: httprequest) -> Bool {
        guard !token.isEmpty else { return false }
        if let value = request.header("authorization"), value.lowercased().hasPrefix("bearer ") {
            let supplied = String(value.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
            return httpserver.matches(supplied, token)
        }
        if let value = request.header("x-auth") {
            return httpserver.matches(value.trimmingCharacters(in: .whitespaces), token)
        }
        return false
    }

    /// Length-independent compare so a wrong token cannot be probed byte by byte.
    private static func matches(_ supplied: String, _ expected: String) -> Bool {
        let a = Array(supplied.utf8)
        let b = Array(expected.utf8)
        var difference: UInt8 = a.count == b.count ? 0 : 1
        let length = min(a.count, b.count)
        if length > 0 {
            for index in 0..<length {
                difference |= a[index] ^ b[index]
            }
        }
        return difference == 0 && a.count == b.count
    }

    private func normalizepath(_ path: String) -> String {
        var value = path.lowercased()
        while value.hasPrefix("/") {
            value.removeFirst()
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    // MARK: payloads

    private func indexpayload() -> [String: Any] {
        return [
            "ok": true,
            "name": "lara http control",
            "note": "read-only Memory Lab API; every endpoint except this index needs the token",
            "auth": ["Authorization": "Bearer <token>", "X-Auth": "<token>"],
            "endpoints": [
                "GET /status",
                "GET /procs",
                "GET /regions?pid=N&preset=0&large=0",
                "POST /dump (pid, preset, large, cap)",
                "POST /strings (pid, keyword, large, cap)",
                "GET /jobs",
                "GET /jobs/<id>?tail=N",
                "DELETE /jobs/<id>",
                "GET /dirs",
                "POST /exploit   (opt-in: httpremoteinit)",
                "POST /sandbox   (opt-in: httpremoteinit)"
            ]
        ]
    }

    /// Kernel readiness gate. Memory endpoints answer 503 + JSON reason instead
    /// of failing silently or hanging when darksword has not run.
    private func readiness() -> (ready: Bool, reason: String, payload: [String: Any]) {
        let memready = mem_is_ready()
        let dsready = laramgr.shared.dsready
        let sbxready = laramgr.shared.sbxready
        let ready = memready && dsready
        let reason = ready ? "" : "kernel read/write is not ready: run the exploit (Darksword) in lara first"
        let payload: [String: Any] = [
            "ok": ready,
            "error": reason,
            "mem_is_ready": memready,
            "dsready": dsready,
            "sbxready": sbxready
        ]
        return (ready, reason, payload)
    }

    private func statuspayload() -> [String: Any] {
        let memready = mem_is_ready()
        let dsready = laramgr.shared.dsready
        let sbxready = laramgr.shared.sbxready
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"

        var payload: [String: Any] = [
            "ok": memready && dsready,
            "kernel": ["mem_is_ready": memready, "dsready": dsready, "sbxready": sbxready],
            "app": [
                "bundle": Bundle.main.bundleIdentifier ?? "",
                "version": version,
                "build": build
            ],
            "device": [
                "machine": httpserver.machinemodel(),
                "system": ProcessInfo.processInfo.operatingSystemVersionString
            ],
            "server": [
                "running": isrunning,
                "status": status,
                "port": Int(boundport),
                "requests": requestcount,
                "uptime": Date().timeIntervalSince(startedat),
                "token_required": true
            ],
            "dumps_dir": mem_dumps_dir() ?? "",
            "jobs": ["total": jobs.count, "running": jobs.values.filter { $0.state == "running" }.count]
        ]
        if let id = lastjobid, let job = jobs[id] {
            payload["job"] = job.summary()
        }
        return payload
    }

    /// POST /exploit and POST /sandbox: the same actions as the on-screen
    /// buttons, so they stay opt-in ("httpremoteinit") even though every
    /// endpoint is token gated. Nothing else in this API needs them.
    private func handlestart(_ request: httprequest, conversation: httpconversation, kind: String) -> Int {
        guard UserDefaults.standard.bool(forKey: "httpremoteinit") else {
            return respond(conversation, 403, [
                "ok": false,
                "error": "remote init is disabled: turn on \"Allow remote init\" in lara's HTTP Control screen",
                "endpoint": "/\(kind)"
            ])
        }

        if kind == "exploit" {
            guard !laramgr.shared.dsready else {
                return respond(conversation, 409, ["ok": false, "error": "the exploit is already running (dsready)"])
            }
            log("running the exploit on request (POST /exploit)")
            DispatchQueue.main.async {
                offsets_init()
                laramgr.shared.run()
            }
            return respond(conversation, 202, [
                "ok": true,
                "action": "exploit",
                "state": "running",
                "hint": "poll GET /status until kernel.dsready is true"
            ])
        }

        guard laramgr.shared.dsready else {
            return respond(conversation, 503, [
                "ok": false,
                "error": "kernel read/write is not ready: run POST /exploit first"
            ])
        }
        log("initializing vfs + sandbox escape on request (POST /sandbox)")
        DispatchQueue.main.async {
            laramgr.shared.vfsinit()
            laramgr.shared.sbxescape()
        }
        return respond(conversation, 202, [
            "ok": true,
            "action": "sandbox",
            "state": "running",
            "hint": "poll GET /status until kernel.sbxready is true"
        ])
    }

    private func handleprocs(_ conversation: httpconversation) -> Int {
        let state = readiness()
        guard state.ready else {
            return respond(conversation, 503, state.payload)
        }
        let procs = mem_procs() ?? []
        return respond(conversation, 200, ["ok": true, "count": procs.count, "processes": procs])
    }

    private func handleregions(_ request: httprequest, _ conversation: httpconversation) -> Int {
        let state = readiness()
        guard state.ready else {
            return respond(conversation, 503, state.payload)
        }
        guard let pid = request.int("pid"), pid > 0 else {
            return respond(conversation, 400, ["ok": false, "error": "pid must be a positive integer"])
        }
        let preset = min(2, max(0, request.int("preset") ?? 0))
        let large = request.bool("large", default: false) || request.bool("includelarge", default: false)

        let dict = mem_regions(pid_t(pid), NSInteger(preset), large) ?? [:]
        var payload = httpserver.jsondictionary(dict)
        if let error = payload["error"] as? String, !error.isEmpty {
            payload["ok"] = false
            return respond(conversation, 404, payload)
        }
        payload["ok"] = true
        payload["preset"] = preset
        payload["large"] = large
        return respond(conversation, 200, payload)
    }

    private func handledirs(_ conversation: httpconversation) -> Int {
        let manager = FileManager.default
        let base = mem_dumps_dir() ?? ""
        guard !base.isEmpty else {
            return respond(conversation, 200, ["ok": true, "dir": "", "count": 0, "folders": []])
        }

        var folders: [[String: Any]] = []
        if let names = try? manager.contentsOfDirectory(atPath: base) {
            for name in names.sorted() {
                let path = (base as NSString).appendingPathComponent(name)
                var isdir = ObjCBool(false)
                guard manager.fileExists(atPath: path, isDirectory: &isdir), isdir.boolValue else { continue }
                let attributes = try? manager.attributesOfItem(atPath: path)
                let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
                let modified = (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                folders.append([
                    "name": name,
                    "path": path,
                    "size": httpserver.foldersize(path),
                    "files": httpserver.filecount(path),
                    "manifest_size": size,
                    "modified": modified.timeIntervalSince1970,
                    "modified_utc": httpserver.iso8601.string(from: modified),
                    "in_progress": name.hasSuffix(".tmp"),
                    "kind": name.hasPrefix("strings-") ? "strings" : "dump"
                ])
            }
        }
        folders.sort { (( $0["modified"] as? Double) ?? 0) > (( $1["modified"] as? Double) ?? 0) }
        return respond(conversation, 200, ["ok": true, "dir": base, "count": folders.count, "folders": folders])
    }

    private static func foldersize(_ path: String) -> UInt64 {
        var total: UInt64 = 0
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: path) else { return 0 }
        for case let name as String in enumerator {
            let full = (path as NSString).appendingPathComponent(name)
            if let attributes = try? manager.attributesOfItem(atPath: full),
               let size = (attributes[.size] as? NSNumber)?.uint64Value {
                total += size
            }
        }
        return total
    }

    private static func filecount(_ path: String) -> Int {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: path) else { return 0 }
        var count = 0
        for case let name as String in enumerator {
            var isdir = ObjCBool(false)
            _ = manager.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &isdir)
            if !isdir.boolValue { count += 1 }
        }
        return count
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: jobs

    private func enqueuejob(_ request: httprequest, kind: String, conversation: httpconversation) -> Int {
        let active = jobs.values.filter { $0.state == "queued" || $0.state == "running" }.count
        guard active < httpserver.maxactivejobs else {
            return respond(conversation, 429, [
                "ok": false,
                "error": "too many active jobs (\(active)); wait for one to finish",
                "jobs": jobs.values.filter { $0.state == "queued" || $0.state == "running" }.map { $0.summary() }
            ])
        }

        guard let pid = request.int("pid"), pid > 0 else {
            return respond(conversation, 400, ["ok": false, "error": "pid must be a positive integer"])
        }
        guard pid > 1 else {
            return respond(conversation, 400, ["ok": false, "error": "pid 1 is not dumpable from userspace; pass a real process pid"])
        }

        var cap: UInt64 = 0
        if let raw = request.param("cap"), !raw.isEmpty {
            guard let parsed = httpserver.parsebytes(raw) else {
                return respond(conversation, 400, ["ok": false, "error": "cap must be bytes (e.g. 67108864) or a size like 64mb"])
            }
            cap = min(parsed, httpserver.capmax)
        }

        let state = readiness()
        guard state.ready else {
            return respond(conversation, 503, state.payload)
        }

        let preset = min(2, max(0, request.int("preset") ?? 0))
        let large = request.bool("large", default: false) || request.bool("includelarge", default: false)
        let keyword = kind == "strings" ? (request.param("keyword") ?? "") : ""

        let id = newjobid()
        let job = httpjob(id: id, kind: kind, pid: pid_t(pid), preset: preset,
                          includeLarge: large, cap: cap, keyword: keyword)
        job.cancelpointer = UnsafeMutablePointer<ObjCBool>.allocate(capacity: 1)
        job.cancelpointer?.initialize(to: ObjCBool(false))

        jobs[id] = job
        joborder.append(id)
        lastjobid = id
        trimjobs()
        publishjobs()

        log("job \(id) queued: \(kind) pid \(pid) preset \(preset) large \(large) cap \(cap)"
            + (kind == "strings" ? " keyword \"\(keyword)\"" : ""))

        jobqueue.async { [weak self] in
            self?.run(job)
        }

        return respond(conversation, 202, [
            "ok": true,
            "id": id,
            "job": job.summary(),
            "hint": "poll GET /jobs/\(id) for state, progress and log; DELETE it to cancel"
        ])
    }

    private func newjobid() -> String {
        for _ in 0..<16 {
            let candidate = String(format: "%08x", arc4random())
            if jobs[candidate] == nil {
                return candidate
            }
        }
        return UUID().uuidString.lowercased()
    }

    private func trimjobs() {
        while joborder.count > httpserver.keepjobs {
            let oldest = joborder.removeFirst()
            if let job = jobs.removeValue(forKey: oldest), job.state == "queued" || job.state == "running" {
                job.cancel = true
                job.cancelpointer?.pointee = ObjCBool(true)
            }
        }
    }

    /// Runs on the job queue. Only immutable job fields and the cancel pointer
    /// are touched here; everything else hops back onto the serial queue.
    private func run(_ job: httpjob) {
        let flag = job.cancelpointer
        var proceed = false
        queue.sync {
            guard self.jobs[job.id] != nil else { return }
            if job.cancel {
                job.state = "cancelled"
                job.ended = Date()
                job.cancelpointer?.deallocate()
                job.cancelpointer = nil
                self.log("job \(job.id) cancelled before it started")
                self.finishpublish(job)
                return
            }
            job.state = "running"
            self.publishjobs()
            proceed = true
        }
        guard proceed, let flag else { return }

        let result: [AnyHashable: Any]
        if job.kind == "strings" {
            result = mem_quick_strings(
                job.pid,
                job.includeLarge,
                job.cap,
                mem_dumps_dir(),
                job.keyword,
                { value in
                    self.progressupdate(job, value)
                },
                { message in
                    self.logline(job, message ?? "")
                },
                flag
            ) ?? [:]
        } else {
            result = mem_dump_process(
                job.pid,
                NSInteger(job.preset),
                job.includeLarge,
                job.cap,
                mem_dumps_dir(),
                { value in
                    self.progressupdate(job, value)
                },
                { message in
                    self.logline(job, message ?? "")
                },
                flag
            ) ?? [:]
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard let stored = self.jobs[job.id] else {
                job.cancelpointer?.deallocate()
                job.cancelpointer = nil
                return
            }
            stored.result = httpserver.jsondictionary(result)
            let cancelled = (result["cancelled"] as? Bool) ?? false
            let ok = (result["ok"] as? Bool) ?? false
            stored.state = cancelled ? "cancelled" : (ok ? "done" : "failed")
            if ok || cancelled {
                stored.progress = 1.0
            }
            stored.ended = Date()
            stored.cancelpointer?.deallocate()
            stored.cancelpointer = nil
            let written = (result["written"] as? NSNumber)?.uint64Value ?? (result["bytes"] as? NSNumber)?.uint64Value ?? 0
            let path = (result["path"] as? String) ?? ""
            self.log("job \(stored.id) \(stored.state) (\(written) bytes, \(String(format: "%.1f", stored.ended!.timeIntervalSince(stored.started))) s)"
                     + (path.isEmpty ? "" : " -> \(path)"))
            if let error = result["error"] as? String, !error.isEmpty, stored.state == "failed" {
                self.log("job \(stored.id) error: \(error)")
            }
            self.finishpublish(stored)
        }
    }

    private func finishpublish(_ job: httpjob) {
        publish { server in
            server.jobline = job.lines.last ?? ""
        }
        publishjobs()
    }

    private func progressupdate(_ job: httpjob, _ value: Double) {
        queue.async { [weak self] in
            guard let self, let stored = self.jobs[job.id] else { return }
            stored.progress = value
            // throttle UI updates to one per percent
            if Int(value * 100) != Int(stored.completed * 100) {
                stored.completed = value
                self.publishjobs()
            }
        }
    }

    private func logline(_ job: httpjob, _ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let stored = self.jobs[job.id] else { return }
            stored.lines.append(text)
            if stored.lines.count > httpserver.joblinelimit {
                stored.lines.removeFirst(stored.lines.count - httpserver.joblinelimit)
            }
            self.publishjobline(text)
        }
        DispatchQueue.main.async {
            globallogger.log("(mem) \(text)")
        }
    }

    private func requestcancel(_ job: httpjob) {
        switch job.state {
        case "queued", "running":
            job.cancel = true
            job.cancelpointer?.pointee = ObjCBool(true)
            log("job \(job.id) cancel requested")
            publishjobs()
        default:
            break
        }
    }

    private func handlejob(id: String, request: httprequest, conversation: httpconversation) -> Int {
        guard let job = jobs[id] else {
            return respond(conversation, 404, ["ok": false, "error": "unknown job \(id)"])
        }

        switch request.method {
        case "GET":
            var payload: [String: Any] = ["ok": true]
            var detail = job.detail()
            if let tail = request.int("tail"), tail > 0 {
                detail["log"] = Array(job.lines.suffix(tail))
                detail["log_tail"] = tail
            }
            payload["job"] = detail
            return respond(conversation, 200, payload)

        case "DELETE":
            if job.state == "queued" || job.state == "running" {
                requestcancel(job)
                return respond(conversation, 200, ["ok": true, "cancel_requested": true, "job": job.summary()])
            }
            return respond(conversation, 409, [
                "ok": false,
                "cancel_requested": false,
                "error": "job already \(job.state)",
                "job": job.summary()
            ])

        default:
            return respond(conversation, 405, ["ok": false, "error": "\(request.method) is not supported for /jobs/<id>"],
                           headers: ["Allow": "GET, DELETE"])
        }
    }

    // MARK: responses

    private func respond(_ conversation: httpconversation, _ code: Int, _ body: Any, headers: [String: String] = [:]) -> Int {
        let payload: Data
        if JSONSerialization.isValidJSONObject(body),
           let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]) {
            payload = data
        } else if let sanitized = httpserver.jsonvalue(body) as? [String: Any],
                  JSONSerialization.isValidJSONObject(sanitized),
                  let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys, .withoutEscapingSlashes]) {
            payload = data
        } else {
            payload = Data("{\"ok\":false,\"error\":\"response serialization failed\"}".utf8)
        }

        var head = "HTTP/1.1 \(code) \(httpserver.reason(code))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(payload)

        conversation.connection.send(content: out, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.teardown(conversation)
        })
        return code
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    // MARK: helpers

    /// Bridges Objective-C containers into plain JSON types. Only read-only
    /// values come out of memdump.h, so the result is safe to serialise.
    static func jsonvalue(_ value: Any) -> Any {
        switch value {
        case let value as NSNull:
            return NSNull()
        case let value as String:
            return value
        case let value as Data:
            return "<\(value.count) bytes>"
        case let value as Date:
            return value.timeIntervalSince1970
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue
            }
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Int64:
            return value
        case let value as UInt64:
            return value
        case let value as Double:
            return value
        case let value as [Any]:
            return value.map { jsonvalue($0) }
        case let value as [AnyHashable: Any]:
            var result: [String: Any] = [:]
            for (key, item) in value {
                result[String(describing: key)] = jsonvalue(item)
            }
            return result
        default:
            return String(describing: value)
        }
    }

    static func jsondictionary(_ value: Any) -> [String: Any] {
        if let nested = jsonvalue(value) as? [String: Any] {
            return nested
        }
        return [:]
    }

    static func parsebytes(_ raw: String) -> UInt64? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        var digits = text
        var multiplier: UInt64 = 1
        for (suffix, factor) in [("kib", 1024), ("kb", 1024), ("k", 1024),
                                 ("mib", 1048576), ("mb", 1048576), ("m", 1048576),
                                 ("gib", 1073741824), ("gb", 1073741824), ("g", 1073741824)] {
            if text.hasSuffix(suffix) {
                multiplier = UInt64(factor)
                digits = String(text.dropLast(suffix.count))
                break
            }
        }
        guard let value = UInt64(digits.trimmingCharacters(in: .whitespaces)) else { return nil }
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : result
    }

    static func machinemodel() -> String {
        var systeminfo = utsname()
        guard uname(&systeminfo) == 0 else { return "unknown" }
        let value = withUnsafePointer(to: &systeminfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) }
        }
        return value ?? "unknown"
    }
}
