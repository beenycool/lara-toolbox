//
//  HTTPView.swift
//  lara
//
//  UI for the built in HTTP control API. Remote control for the Memory Lab
//  over Wi-Fi: status, process list, region map, async memory dumps and quick
//  strings scans, with progress and cancellation.
//
//  The server starts automatically at launch (toggle below), so the normal
//  way to use it is curl from a laptop, not this screen.
//

import SwiftUI
import UIKit

struct HTTPView: View {
    @ObservedObject private var server = httpserver.shared
    @ObservedObject private var mgr = laramgr.shared

    @AppStorage("httpport") private var port: Int = 8383
    @AppStorage("httpenabled") private var enabled: Bool = true
    @AppStorage("httpkeeprunning") private var keeprunning: Bool = true
    @AppStorage("httptoken") private var token: String = ""
    @AppStorage("ftppassword") private var ftppassword: String = ""
    @AppStorage("httpremoteinit") private var remoteinit: Bool = false
    @AppStorage("httpstartftp") private var startftp: Bool = false

    @State private var porttext: String = "8383"
    @State private var ipv4: String?
    @State private var ipv6: String?
    @State private var reveal = false

    var body: some View {
        NavigationStack {
            List {
                serverSection
                connectionSection
                tokenSection
                behaviourSection
                jobsSection
                endpointsSection
                logSection
            }
            .navigationTitle("HTTP Control")
            .onAppear {
                porttext = String(port)
                refreshaddresses()
                if token.isEmpty {
                    token = server.resolvedtoken()
                }
                if !server.isrunning {
                    // respects the auto-start toggle and a manual stop
                    server.autostart()
                }
            }
            .onDisappear {
                if !keeprunning {
                    server.stop()
                }
            }
            .onChange(of: porttext) { newvalue in
                let digits = newvalue.filter { $0.isNumber }
                if digits != newvalue {
                    porttext = digits
                    return
                }
                if let value = Int(digits), value > 0, value <= 65535 {
                    port = value
                }
            }
        }
    }

    // MARK: sections

    private var serverSection: some View {
        Section {
            if !mgr.dsready {
                Text("Kernel R/W is not ready. The API answers 503 until the exploit has run.")
                    .foregroundColor(.secondary)
            }

            Label {
                Text("Anyone on this Wi-Fi network who has the token can list and dump the memory of any process on this device, and can read the dump files over the existing FTP server. Traffic is plain HTTP.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundColor(.red)

            Toggle("HTTP Control API", isOn: Binding(
                get: { server.isrunning },
                set: { wanted in
                    if wanted {
                        startserver()
                    } else {
                        server.stop()
                    }
                }
            ))

            HStack {
                Text("Status")
                Spacer()
                Text(server.status)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(server.isrunning ? .green : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Text("Requests served")
                Spacer()
                Text("\(server.requestcount)")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if !server.jobline.isEmpty {
                HStack {
                    Text("Job output")
                    Spacer()
                    Text(server.jobline)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } header: {
            HeaderLabel(text: "Server", icon: "network")
        } footer: {
            Text("The API is read-only: it can list processes and their memory maps, and copy memory out of a process. It never writes to another process.")
        }
    }

    private var connectionSection: some View {
        Section {
            HStack {
                Text("Device IP")
                Spacer()
                Text(displayaddress)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(ipv4 != nil || ipv6 != nil ? .secondary : .red)
                Button {
                    refreshaddresses()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            HStack {
                Text("Port")
                Spacer()
                TextField("8383", text: $porttext)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospaced()
                    .frame(maxWidth: 90)
            }
            .disabled(server.isrunning)

            if let address = ipv4 {
                HStack {
                    Text("URL")
                    Spacer()
                    Text("http://\(address):\(porttext)/status")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = "http://\(address):\(porttext)/status"
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        } header: {
            HeaderLabel(text: "Connection", icon: "wifi")
        } footer: {
            Text("Reachable over Wi-Fi only, on the port above. Change the port while the server is stopped.")
        }
    }

    private var tokenSection: some View {
        Section {
            HStack {
                Text("Token")
                Spacer()
                Text(reveal ? displaytoken : maskedtoken)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                }
            }

            HStack {
                Button {
                    UIPasteboard.general.string = displaytoken
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label("Copy Token", systemImage: "doc.on.doc")
                }
                .disabled(displaytoken.isEmpty)

                Spacer()

                Button {
                    token = httpserver.generatetoken()
                } label: {
                    Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(server.isrunning)
            }

            if server.tokenisfromftp() {
                Text("The token currently matches the FTP password. Regenerating gives the API its own secret.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            HeaderLabel(text: "Authentication", icon: "person.badge.key")
        } footer: {
            Text("Send it as \"Authorization: Bearer <token>\" or \"X-Auth: <token>\". The server refuses to start without one. Stop the server to change the token.")
        }
    }

    private var behaviourSection: some View {
        Section {
            Toggle("Start automatically", isOn: $enabled)
            Toggle("Keep running in background", isOn: $keeprunning)
            Toggle("Allow remote init (POST /exploit, /sandbox)", isOn: $remoteinit)
            Toggle("Start the FTP server too", isOn: $startftp)
        } header: {
            HeaderLabel(text: "Behaviour", icon: "gearshape")
        } footer: {
            Text("Start automatically brings the listener up at launch, before the exploit has run, so the API answers 503 instead of refusing connections. Keep running in background keeps the listener alive after leaving this screen; iOS may still suspend the app, and no request can be served while it is suspended. Allow remote init lets the token holder run Darksword and the sandbox escape over HTTP, which is how a fully hands-off session works; leave it off if you prefer to tap Run Exploit yourself. Start the FTP server too calls the unchanged FTP server with the credentials saved in its screen, so the full-disk fallback is up after a launch without visiting that screen.")
        }
    }

    private var jobsSection: some View {
        Section {
            if server.joblist.isEmpty {
                Text("No jobs yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(server.joblist.enumerated()), id: \.offset) { _, job in
                    jobrow(job)
                }
            }
        } header: {
            HeaderLabel(text: "Recent jobs", icon: "list.bullet.rectangle")
        } footer: {
            Text("Started with POST /dump or POST /strings. Cancel a running job with DELETE /jobs/<id> or the button above.")
        }
    }

    private func jobrow(_ job: [String: Any]) -> some View {
        let id = (job["id"] as? String) ?? "?"
        let kind = (job["kind"] as? String) ?? "?"
        let state = (job["state"] as? String) ?? "?"
        let pid = (job["pid"] as? NSNumber)?.intValue ?? 0
        let progress = (job["progress"] as? NSNumber)?.doubleValue ?? 0
        let active = state == "running" || state == "queued"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(kind) \(id)")
                    .font(.system(.subheadline, design: .monospaced))
                Spacer()
                Text(state)
                    .font(.caption2.bold())
                    .foregroundColor(state == "done" ? .green : (state == "failed" ? .red : .secondary))
                if active {
                    Button("Cancel") {
                        server.cancel(jobid: id)
                    }
                    .font(.caption.bold())
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("pid \(pid)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", progress * 100))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if active {
                ProgressView(value: progress)
            }
            if let path = job["path"] as? String, !path.isEmpty {
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let error = job["error"] as? String, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var endpointsSection: some View {
        Section {
            ForEach(Array(endpoints.enumerated()), id: \.offset) { _, endpoint in
                VStack(alignment: .leading, spacing: 2) {
                    Text(endpoint.0)
                        .font(.system(.subheadline, design: .monospaced))
                    Text(endpoint.1)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            HeaderLabel(text: "Endpoints", icon: "curlybraces")
        } footer: {
            Text("Example: curl -H \"Authorization: Bearer <token>\" http://<device-ip>:\(porttext)/procs")
        }
    }

    private var logSection: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView {
                    if server.logs.isEmpty {
                        Text("No activity yet.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(server.logs.enumerated()), id: \.offset) { _, entry in
                                Text(entry)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(height: 220)
                .onChange(of: server.logs.count) { _ in
                    if let last = server.logs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            HStack {
                Text("\(server.logs.count) lines")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") {
                    server.clearlogs()
                }
                .disabled(server.logs.isEmpty)
            }
        } header: {
            HeaderLabel(text: "Log", icon: "terminal")
        }
    }

    // MARK: helpers

    private let endpoints: [(String, String)] = [
        ("GET /status", "readiness (mem_is_ready, dsready, sbxready), app version, ports, current job"),
        ("GET /procs", "every process except kernel_task, from mem_procs()"),
        ("GET /regions?pid=N&preset=0&large=0", "region map for one process; presets 0 heap+data+stack, 1 all readable, 2 full"),
        ("POST /dump?pid=N", "async job: mem_dump_process; also preset, large, cap (0 = 512 MB default)"),
        ("POST /strings?pid=N&keyword=foo", "async job: mem_quick_strings; keyword optional, matches case insensitively"),
        ("GET /jobs", "recent jobs with state and progress"),
        ("GET /jobs/<id>?tail=50", "one job: progress, log lines, result dictionary"),
        ("DELETE /jobs/<id>", "cancel a queued or running job"),
        ("GET /dirs", "completed dump and strings folders in Documents/lara_dumps"),
        ("POST /exploit", "opt-in: run Darksword (same as the Run Exploit button)"),
        ("POST /sandbox", "opt-in: initialize vfs + sandbox escape (Initialize System)")
    ]

    private var displaytoken: String {
        if !token.isEmpty { return token }
        return server.resolvedtoken()
    }

    private var maskedtoken: String {
        let value = displaytoken
        guard value.count > 4 else { return value.isEmpty ? "(none)" : String(repeating: "•", count: value.count) }
        return String(value.prefix(2)) + String(repeating: "•", count: max(4, value.count - 4)) + String(value.suffix(2))
    }

    private var displayaddress: String {
        if let ipv4 {
            return ipv4
        }
        if let ipv6 {
            return ipv6
        }
        return "unavailable"
    }

    private func refreshaddresses() {
        ipv4 = ftpipv4address()
        ipv6 = ftpipv6address()
    }

    private func startserver() {
        guard let value = Int(porttext), value > 0, value <= 65535 else {
            server.log("cannot start: invalid port \"\(porttext)\"")
            return
        }
        guard !server.resolvedtoken().isEmpty else {
            server.log("cannot start: no token configured")
            return
        }
        port = value
        server.start(port: UInt16(value))
    }
}
