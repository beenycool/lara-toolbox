//
//  ftpserver.swift
//  lara
//
//  Created by lara on 11.10.26.
//
//  Minimal passive-mode FTP server built on Network.framework.
//  Serves the full disk with plain FileManager/POSIX calls, so the
//  sandbox escape has to be applied before the server is started.
//  One control client at a time, PASV/EPSV data connections only.
//

import Foundation
import Network
import Combine
import Darwin

// MARK: - device address helpers

private func ftpnetworkaddresses(family: Int32) -> [(name: String, address: String)] {
    var results: [(name: String, address: String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return results }
    defer { freeifaddrs(ifaddr) }

    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        let interface = current.pointee
        if let addr = interface.ifa_addr,
           let name = interface.ifa_name,
           addr.pointee.sa_family == UInt8(family) {
            let flags = Int32(bitPattern: interface.ifa_flags)
            let isup = (flags & IFF_UP) == IFF_UP && (flags & IFF_RUNNING) == IFF_RUNNING
            let isloopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            if isup && !isloopback {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if result == 0 {
                    results.append((String(cString: name), String(cString: host)))
                }
            }
        }
        pointer = interface.ifa_next
    }
    return results
}

private func ftppreferredaddress(family: Int32, preferredname: String) -> String? {
    let all = ftpnetworkaddresses(family: family)
    if let preferred = all.first(where: { $0.name == preferredname }) {
        return preferred.address
    }

    // skip VPN / cellular / peer-to-peer style interfaces unless nothing else exists
    let excludedprefixes = ["lo", "utun", "pdp_ip", "awdl", "llw", "anpi", "ap", "bridge", "ipsec", "tun", "tap", "gif", "stf", "p2p"]
    if let lan = all.first(where: { candidate in
        !excludedprefixes.contains(where: { prefix in candidate.name.hasPrefix(prefix) })
    }) {
        return lan.address
    }

    return all.first?.address
}

/// Best effort IPv4 address of the device (used for the PASV reply and the UI).
func ftpipv4address() -> String? {
    ftppreferredaddress(family: AF_INET, preferredname: "en0")
}

/// Best effort IPv6 address of the device (EPSV only, PASV cannot carry IPv6).
func ftpipv6address() -> String? {
    ftppreferredaddress(family: AF_INET6, preferredname: "en0")
}

// MARK: - server

final class ftpserver: ObservableObject {
    static let shared = ftpserver()

    @Published private(set) var isrunning = false
    @Published private(set) var status = "stopped"
    @Published private(set) var clientconnected = false
    @Published private(set) var clientlabel = ""
    @Published private(set) var remotepath = ""
    @Published private(set) var logs: [String] = []

    private let queue = DispatchQueue(label: "lara.ftpserver")
    private static let loglimit = 400
    private static let timeformatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var listener: NWListener?
    private var control: NWConnection?
    private var controlbuffer = Data()

    private var datalistener: NWListener?
    private var dataconnection: NWConnection?

    private var transfertoken = 0
    private var transferhandle: FileHandle?
    private var transferfd: Int32 = -1

    private var username = "lara"
    private var password = ""
    private var allowanonymous = false
    private var startpath = "/var/mobile"

    private var session: ftpsession?

    deinit {
        listener?.cancel()
        control?.cancel()
        datalistener?.cancel()
        dataconnection?.cancel()
    }

    // MARK: lifecycle

    /// Generates a random password for the UI, avoiding characters that are easy to confuse.
    static func generatepassword(length: Int = 12) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var result = ""
        for _ in 0..<max(4, length) {
            let index = Int(arc4random_uniform(UInt32(alphabet.count)))
            result.append(alphabet[index])
        }
        return result
    }

    @discardableResult
    func start(port: UInt16, startpath: String, username: String, password: String, allowanonymous: Bool) -> Bool {
        guard port > 0, let nwport = NWEndpoint.Port(rawValue: port) else {
            log("invalid port \(port)")
            return false
        }

        let trimmeduser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmeduser.isEmpty || allowanonymous else {
            log("refusing to start: username is empty and anonymous login is disabled")
            return false
        }
        guard !password.isEmpty || allowanonymous else {
            log("refusing to start: password is empty and anonymous login is disabled")
            return false
        }

        let normalized = normalizedpath(startpath) ?? "/"
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        queue.async { [weak self] in
            guard let self else { return }
            guard self.listener == nil else {
                self.log("server is already running")
                return
            }

            self.username = trimmeduser
            self.password = password
            self.allowanonymous = allowanonymous

            var isdir = ObjCBool(false)
            let exists = FileManager.default.fileExists(atPath: normalized, isDirectory: &isdir)
            self.startpath = (exists && isdir.boolValue) ? normalized : "/"

            let listener: NWListener
            do {
                listener = try NWListener(using: parameters, on: nwport)
            } catch {
                self.log("failed to create listener on port \(port): \(error.localizedDescription)")
                self.publish { server in
                    server.isrunning = false
                    server.status = "failed"
                }
                return
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.newConnectionLimit = NWListener.InfiniteConnectionLimit
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.log("listening on port \(port)")
                    self.publish { server in
                        server.isrunning = true
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
            listener.start(queue: self.queue)
            self.log("starting FTP server on port \(port) (start path: \(self.startpath))")
            self.publish { server in
                server.isrunning = true
                server.status = "starting on port \(port)"
            }
        }
        return true
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closesession(reason: "server stopped")
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

    // MARK: logging

    func log(_ message: String) {
        DispatchQueue.main.async {
            let stamp = ftpserver.timeformatter.string(from: Date())
            self.logs.append("\(stamp) \(message)")
            if self.logs.count > ftpserver.loglimit {
                self.logs.removeFirst(self.logs.count - ftpserver.loglimit)
            }
        }
        globallogger.log("(ftp) \(message)")
    }

    private func publish(_ update: @escaping (ftpserver) -> Void) {
        DispatchQueue.main.async {
            update(self)
        }
    }

    // MARK: control connection

    private func accept(_ connection: NWConnection) {
        if control != nil {
            // one client at a time: drop the previous session so stale
            // connections can never lock the server out
            log("new client connected, dropping previous client")
            closesession(reason: "replaced by new client")
        }

        control = connection
        controlbuffer.removeAll()
        session = ftpsession(cwd: startpath)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.control === connection else { return }
            switch state {
            case .ready:
                let label = String(describing: connection.endpoint)
                self.log("client connected: \(label)")
                self.publish { server in
                    server.clientconnected = true
                    server.clientlabel = label
                    server.remotepath = server.session?.cwd ?? ""
                }
                self.send("220 lara FTP server ready.\r\n")
                self.receiveloop(connection)
            case .failed(let error):
                self.closesession(reason: "connection failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveloop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, iscomplete, error in
            guard let self, self.control === connection else { return }
            if let data, !data.isEmpty {
                self.consume(data, from: connection)
            }
            guard self.control === connection else { return }
            if let error {
                self.closesession(reason: "receive error: \(error.localizedDescription)")
                return
            }
            if iscomplete {
                self.closesession(reason: "client closed the connection")
                return
            }
            self.receiveloop(connection)
        }
    }

    private func consume(_ data: Data, from connection: NWConnection) {
        controlbuffer.append(data)

        if controlbuffer.count > 32768 {
            controlbuffer.removeAll()
            send("500 Command line too long.\r\n")
            return
        }

        var consumed = controlbuffer.startIndex
        while consumed < controlbuffer.endIndex, let newline = controlbuffer[consumed...].firstIndex(of: 0x0A) {
            let raw = controlbuffer[consumed..<newline]
            consumed = controlbuffer.index(after: newline)

            var line = String(decoding: raw, as: UTF8.self)
            if line.hasSuffix("\r") {
                line.removeLast()
            }

            handle(line: line, on: connection)
            guard control === connection else { return }
        }

        if consumed > controlbuffer.startIndex {
            controlbuffer.removeSubrange(controlbuffer.startIndex..<consumed)
        }
    }

    private func send(_ text: String, then: @escaping () -> Void = {}) {
        guard let control else {
            then()
            return
        }
        control.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            then()
        })
    }

    private func closesession(reason: String) {
        if let control {
            log("client disconnected (\(reason))")
            control.stateUpdateHandler = nil
            control.cancel()
        }
        control = nil
        controlbuffer.removeAll()
        session = nil
        canceldata()
        publish { server in
            server.clientconnected = false
            server.clientlabel = ""
            server.remotepath = ""
        }
    }

    // MARK: commands

    private func handle(line: String, on connection: NWConnection) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        var verb = parts[0].uppercased()
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        switch verb {
        case "XPWD": verb = "PWD"
        case "XCWD": verb = "CWD"
        case "XMKD": verb = "MKD"
        case "XRMD": verb = "RMD"
        default: break
        }

        if verb == "PASS" {
            log("C> PASS \(argument.isEmpty ? "(empty)" : "(hidden)")")
        } else {
            log("C> \(trimmed)")
        }

        guard let session else {
            send("421 Service not available.\r\n")
            return
        }

        let publicverbs = ["USER", "PASS", "QUIT", "FEAT", "SYST", "NOOP", "OPTS", "CLNT", "HELP", "AUTH", "PBSZ", "PROT"]
        if !session.authenticated && !publicverbs.contains(verb) {
            send("530 Please login with USER and PASS.\r\n")
            return
        }

        switch verb {
        case "USER":
            guard !argument.isEmpty else {
                send("501 Syntax error in parameters.\r\n")
                return
            }
            session.user = argument
            session.authenticated = false
            session.anonymous = false
            send("331 Password required for \(argument).\r\n")

        case "PASS":
            guard let user = session.user else {
                send("503 Login with USER first.\r\n")
                return
            }
            if allowanonymous && (user.lowercased() == "anonymous" || user.lowercased() == "ftp") {
                session.authenticated = true
                session.anonymous = true
                send("230 Anonymous login ok.\r\n")
                publish { server in
                    server.remotepath = session.cwd
                }
                return
            }
            if !username.isEmpty && user == username && !password.isEmpty && argument == password {
                session.authenticated = true
                session.anonymous = false
                send("230 Login successful.\r\n")
                publish { server in
                    server.remotepath = session.cwd
                }
                return
            }
            send("530 Login incorrect.\r\n")

        case "QUIT":
            let connection = control
            send("221 Goodbye.\r\n") { [weak self] in
                guard let self, let connection, self.control === connection else { return }
                self.closesession(reason: "client quit")
            }

        case "SYST":
            send("215 UNIX Type: L8\r\n")

        case "FEAT":
            send("211-Features:\r\n PASV\r\n EPSV\r\n UTF8\r\n SIZE\r\n211 End\r\n")

        case "NOOP":
            send("200 NOOP ok.\r\n")

        case "OPTS":
            if argument.uppercased().hasPrefix("UTF8") {
                send("200 UTF8 set to on.\r\n")
            } else {
                send("501 Option not understood.\r\n")
            }

        case "CLNT":
            send("200 Noted.\r\n")

        case "TYPE":
            let value = argument.uppercased()
            if value == "A" || value == "A N" || value == "A T" {
                session.type = "A"
                send("200 Type set to A.\r\n")
            } else if value == "I" || value == "L 8" || value == "L8" {
                session.type = "I"
                send("200 Type set to I.\r\n")
            } else {
                send("504 Type not supported.\r\n")
            }

        case "PWD":
            send("257 \"\(quoted(session.cwd))\" is the current directory.\r\n")

        case "CWD":
            changedirectory(argument)

        case "CDUP":
            changedirectory("..")

        case "LIST":
            list(argument, long: true)

        case "NLST":
            list(argument, long: false)

        case "SIZE":
            size(argument)

        case "RETR":
            retr(argument)

        case "STOR":
            stor(argument)

        case "DELE":
            dele(argument)

        case "MKD":
            mkd(argument)

        case "RMD":
            rmd(argument)

        case "PASV":
            setuppassive(extended: false)

        case "EPSV":
            if argument.uppercased() == "ALL" {
                session.epsvall = true
                send("200 EPSV ALL ok.\r\n")
                return
            }
            setuppassive(extended: true)

        case "PORT", "EPRT":
            send("502 Active mode is not supported, use PASV or EPSV.\r\n")

        case "ALLO":
            send("202 ALLO ok.\r\n")

        case "HELP":
            send("214-Commands: USER PASS SYST FEAT TYPE PWD CWD CDUP LIST NLST SIZE RETR STOR DELE MKD RMD PASV EPSV NOOP QUIT\r\n214 Help ok.\r\n")

        default:
            send("502 Command not implemented.\r\n")
        }
    }

    // MARK: path handling

    /// Normalizes an FTP path and rejects any attempt to climb above the root.
    private func normalizedpath(_ path: String) -> String? {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(component)
            if part == "." {
                continue
            }
            if part == ".." {
                if components.isEmpty {
                    return nil
                }
                components.removeLast()
                continue
            }
            components.append(part)
        }
        let normalized = "/" + components.joined(separator: "/")
        guard normalized.hasPrefix("/") else { return nil }
        return normalized
    }

    private func resolve(_ argument: String) -> String? {
        guard let session else { return nil }

        var input = argument.trimmingCharacters(in: .whitespaces)
        if input.isEmpty {
            return session.cwd
        }
        if input.contains("\0") {
            return nil
        }
        if input.count >= 2 && input.hasPrefix("\"") && input.hasSuffix("\"") {
            input.removeFirst()
            input.removeLast()
        }

        let combined: String
        if input.hasPrefix("/") {
            combined = input
        } else if session.cwd == "/" {
            combined = "/" + input
        } else {
            combined = session.cwd + "/" + input
        }

        return normalizedpath(combined)
    }

    private func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\"\"")
    }

    private func stripflags(_ argument: String) -> String {
        let tokens = argument.split(separator: " ").map(String.init)
        let remaining = tokens.drop { $0.hasPrefix("-") }
        return remaining.joined(separator: " ")
    }

    // MARK: command implementations

    private func changedirectory(_ argument: String) {
        guard let session, let path = resolve(argument) else {
            send("550 Failed to change directory.\r\n")
            return
        }
        var isdir = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isdir)
        guard exists, isdir.boolValue else {
            send("550 Failed to change directory.\r\n")
            return
        }
        session.cwd = path
        send("250 Directory successfully changed.\r\n")
        publish { server in
            server.remotepath = path
        }
    }

    private func directoryentries(path: String, isdir: Bool) -> [(name: String, path: String)] {
        if !isdir {
            return [((path as NSString).lastPathComponent, path)]
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.sorted { $0.lowercased() < $1.lowercased() }.map { name in
            (name, path == "/" ? "/" + name : path + "/" + name)
        }
    }

    private func list(_ argument: String, long: Bool) {
        guard let path = resolve(stripflags(argument)) else {
            send("550 Unable to list.\r\n")
            return
        }

        var isdir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isdir) else {
            send("550 No such file or directory.\r\n")
            return
        }
        if isdir.boolValue && !FileManager.default.isReadableFile(atPath: path) {
            send("550 Permission denied.\r\n")
            return
        }

        waitfordata { [weak self] connection in
            guard let self else { return }
            let entries = self.directoryentries(path: path, isdir: isdir.boolValue)
            var lines: [String] = []
            for entry in entries {
                lines.append(long ? self.longline(name: entry.name, path: entry.path) : entry.name)
            }
            let text = lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
            self.send("150 Here comes the directory listing.\r\n")
            self.senddata(Data(text.utf8), on: connection) { ok in
                self.completedata(success: ok)
            }
        }
    }

    private func longline(name: String, path: String) -> String {
        let fm = FileManager.default
        var isdir = ObjCBool(false)
        _ = fm.fileExists(atPath: path, isDirectory: &isdir)

        var islink = false
        var permissions = "rwxrwxrwx"
        var owner = "mobile"
        var group = "mobile"
        var size: Int64 = 0
        var modified = Date()

        if let attributes = try? fm.attributesOfItem(atPath: path) {
            if let number = attributes[.posixPermissions] as? NSNumber {
                permissions = permissionstring(number.uint16Value)
            }
            if let value = attributes[.ownerAccountName] as? String {
                owner = value
            }
            if let value = attributes[.groupOwnerAccountName] as? String {
                group = value
            }
            if let number = attributes[.size] as? NSNumber {
                size = number.int64Value
            }
            if let value = attributes[.modificationDate] as? Date {
                modified = value
            }
            if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                islink = true
            }
        }

        let typechar = islink ? "l" : (isdir.boolValue ? "d" : "-")
        var line = "\(typechar)\(permissions) 1 \(owner) \(group) \(String(format: "%9lld", size)) \(datestring(modified)) \(name)"
        if islink, let target = try? fm.destinationOfSymbolicLink(atPath: path) {
            line += " -> \(target)"
        }
        return line
    }

    private func permissionstring(_ mode: UInt16) -> String {
        let bits: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x")
        ]
        var result = ""
        for (bit, character) in bits {
            result.append((mode & bit) != 0 ? character : "-")
        }
        return result
    }

    private static let monthnames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private func datestring(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.month, .day, .year, .hour, .minute], from: date)
        let month = ftpserver.monthnames[max(0, min(11, (components.month ?? 1) - 1))]
        let day = components.day ?? 1
        if abs(date.timeIntervalSinceNow) > 180 * 24 * 60 * 60 {
            return String(format: "%@ %2d  %d", month, day, components.year ?? 1970)
        }
        return String(format: "%@ %2d %02d:%02d", month, day, components.hour ?? 0, components.minute ?? 0)
    }

    private func size(_ argument: String) {
        guard let path = resolve(argument) else {
            send("550 Could not get file size.\r\n")
            return
        }
        var isdir = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isdir)
        guard exists, !isdir.boolValue else {
            send("550 Could not get file size.\r\n")
            return
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let number = attributes[.size] as? NSNumber {
            send("213 \(number.int64Value)\r\n")
        } else {
            send("550 Could not get file size.\r\n")
        }
    }

    private func retr(_ argument: String) {
        guard let path = resolve(argument) else {
            send("550 No such file or directory.\r\n")
            return
        }
        var isdir = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isdir)
        guard exists, !isdir.boolValue else {
            send("550 No such file or directory.\r\n")
            return
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            send("550 Permission denied.\r\n")
            return
        }

        waitfordata { [weak self] connection in
            guard let self else { return }
            guard let handle = FileHandle(forReadingAtPath: path) else {
                self.canceldata()
                self.send("550 Failed to open file.\r\n")
                return
            }
            self.transferhandle = handle
            self.send("150 Opening data connection.\r\n")
            let token = self.starttransfer()
            self.sendfile(handle: handle, on: connection, token: token)
        }
    }

    private func stor(_ argument: String) {
        guard let path = resolve(argument) else {
            send("550 Failed to open file for writing.\r\n")
            return
        }
        var isdir = ObjCBool(false)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isdir), isdir.boolValue {
            send("550 Is a directory.\r\n")
            return
        }

        waitfordata { [weak self] connection in
            guard let self else { return }
            santanderfs.clearImmutableIfPossible(atPath: path)
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else {
                self.canceldata()
                self.send("550 Failed to open file for writing.\r\n")
                return
            }
            self.transferfd = fd
            self.send("150 Ok to send data.\r\n")
            let token = self.starttransfer()
            self.recvfile(on: connection, token: token)
        }
    }

    private func dele(_ argument: String) {
        guard let path = resolve(argument) else {
            send("550 Delete operation failed.\r\n")
            return
        }
        var isdir = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isdir)
        guard exists, !isdir.boolValue else {
            send("550 Delete operation failed.\r\n")
            return
        }
        santanderfs.clearImmutableIfPossible(atPath: path)
        do {
            try FileManager.default.removeItem(atPath: path)
            send("250 Delete operation successful.\r\n")
        } catch {
            send("550 Delete operation failed.\r\n")
        }
    }

    private func mkd(_ argument: String) {
        guard let path = resolve(argument), path != "/" else {
            send("550 Create directory operation failed.\r\n")
            return
        }
        guard !FileManager.default.fileExists(atPath: path) else {
            send("550 File exists.\r\n")
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: nil)
            send("257 \"\(quoted(path))\" created.\r\n")
        } catch {
            send("550 Create directory operation failed.\r\n")
        }
    }

    private func rmd(_ argument: String) {
        guard let path = resolve(argument), path != "/" else {
            send("550 Remove directory operation failed.\r\n")
            return
        }
        var isdir = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isdir)
        guard exists, isdir.boolValue else {
            send("550 Remove directory operation failed.\r\n")
            return
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            send("250 Remove directory operation successful.\r\n")
        } catch {
            send("550 Remove directory operation failed.\r\n")
        }
    }

    // MARK: passive data connections

    private func setuppassive(extended: Bool) {
        canceldata()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            log("failed to create data listener: \(error.localizedDescription)")
            send("425 Can't open data connection.\r\n")
            return
        }

        datalistener = listener

        listener.newConnectionLimit = NWListener.InfiniteConnectionLimit
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener, self.datalistener === listener else {
                connection.cancel()
                return
            }
            guard self.dataconnection == nil else {
                self.log("rejecting extra data connection")
                connection.cancel()
                return
            }
            self.dataconnection = connection
            self.monitordata(connection)
            connection.start(queue: self.queue)
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.datalistener === listener else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else {
                    self.log("data listener did not report a port")
                    self.canceldata()
                    self.send("425 Can't open data connection.\r\n")
                    return
                }
                self.log("data listener ready on port \(port)")
                if extended {
                    self.send("229 Entering Extended Passive Mode (|||\(port)|).\r\n")
                } else if let address = ftpipv4address() {
                    let numbers = address.split(separator: ".").map(String.init)
                    if numbers.count == 4 {
                        let hi = Int(port) / 256
                        let lo = Int(port) % 256
                        self.send("227 Entering Passive Mode (\(numbers[0]),\(numbers[1]),\(numbers[2]),\(numbers[3]),\(hi),\(lo)).\r\n")
                    } else {
                        self.log("unexpected IPv4 address: \(address)")
                        self.canceldata()
                        self.send("425 Can't open data connection.\r\n")
                    }
                } else {
                    self.log("no IPv4 address available for PASV")
                    self.canceldata()
                    self.send("425 Can't open data connection, use EPSV.\r\n")
                }
            case .failed(let error):
                self.log("data listener failed: \(error.localizedDescription)")
                if self.datalistener === listener {
                    self.datalistener = nil
                }
                self.send("425 Can't open data connection.\r\n")
            default:
                break
            }
        }

        listener.start(queue: queue)
        log("opening passive data listener")
    }

    private func monitordata(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.dataconnection === connection else { return }
            switch state {
            case .ready:
                self.log("data connection established")
            case .failed(let error):
                self.log("data connection failed: \(error.localizedDescription)")
            default:
                break
            }
        }
    }

    private func canceldata() {
        endtransfer()
        if let dataconnection {
            dataconnection.stateUpdateHandler = nil
            dataconnection.cancel()
        }
        dataconnection = nil
        if let datalistener {
            datalistener.newConnectionHandler = nil
            datalistener.stateUpdateHandler = nil
            datalistener.cancel()
        }
        datalistener = nil
    }

    private func waitfordata(remaining: Int = 50, _ body: @escaping (NWConnection) -> Void) {
        if let dataconnection {
            body(dataconnection)
            return
        }
        if remaining == 0 {
            canceldata()
            send("425 Use PASV or EPSV first.\r\n")
            return
        }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitfordata(remaining: remaining - 1, body)
        }
    }

    // MARK: transfers

    private func starttransfer() -> Int {
        transfertoken += 1
        return transfertoken
    }

    private func workiscurrent(_ token: Int) -> Bool {
        transfertoken == token
    }

    private func endtransfer() {
        transfertoken += 1
        if let handle = transferhandle {
            try? handle.close()
            transferhandle = nil
        }
        if transferfd >= 0 {
            close(transferfd)
            transferfd = -1
        }
    }

    private func completedata(success: Bool) {
        canceldata()
        send(success ? "226 Transfer complete.\r\n" : "426 Transfer aborted.\r\n")
    }

    private func senddata(_ data: Data, on connection: NWConnection, completion: @escaping (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, self.dataconnection === connection else { return }
            completion(error == nil)
        })
    }

    private func sendfile(handle: FileHandle, on connection: NWConnection, token: Int) {
        guard workiscurrent(token), dataconnection === connection else { return }

        let chunk: Data
        if #available(iOS 13.4, *) {
            chunk = (try? handle.read(upToCount: 65536)) ?? Data()
        } else {
            chunk = handle.readData(ofLength: 65536)
        }

        if chunk.isEmpty {
            completedata(success: true)
            return
        }

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, self.workiscurrent(token), self.dataconnection === connection else { return }
            if error != nil {
                self.completedata(success: false)
                return
            }
            self.sendfile(handle: handle, on: connection, token: token)
        })
    }

    private func recvfile(on connection: NWConnection, token: Int) {
        guard workiscurrent(token), dataconnection === connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, iscomplete, error in
            guard let self, self.workiscurrent(token), self.dataconnection === connection else { return }

            if let data, !data.isEmpty, self.transferfd >= 0 {
                let ok = data.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return raw.count == 0 }
                    var offset = 0
                    while offset < raw.count {
                        let written = write(self.transferfd, base.advanced(by: offset), raw.count - offset)
                        if written <= 0 { return false }
                        offset += written
                    }
                    return true
                }
                if !ok {
                    self.completedata(success: false)
                    return
                }
            }

            if error != nil {
                self.completedata(success: false)
                return
            }
            if iscomplete {
                self.completedata(success: true)
                return
            }
            self.recvfile(on: connection, token: token)
        }
    }
}

// MARK: - session

private final class ftpsession {
    var user: String?
    var authenticated = false
    var anonymous = false
    var type: Character = "I"
    var cwd: String
    var epsvall = false

    init(cwd: String) {
        self.cwd = cwd
    }
}
