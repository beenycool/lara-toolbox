//
//  FTPView.swift
//  lara
//
//  Created by lara on 11.10.26.
//
//  UI for the built in FTP server. Full disk file access over Wi-Fi,
//  served straight from the phone. Starting the server needs the
//  sandbox escape to be applied first.
//

import SwiftUI
import UIKit

struct FTPView: View {
    @ObservedObject private var server = ftpserver.shared
    @ObservedObject private var mgr = laramgr.shared

    @AppStorage("ftpport") private var port: Int = 2121
    @AppStorage("ftpusername") private var username: String = "lara"
    @AppStorage("ftppassword") private var password: String = ""
    @AppStorage("ftpallowanonymous") private var allowanonymous: Bool = false
    @AppStorage("ftpstartinmobile") private var startinmobile: Bool = true
    @AppStorage("ftpkeeprunning") private var keeprunning: Bool = false
    @AppStorage("ftpreadonly") private var readonly: Bool = false

    @State private var porttext: String = "2121"
    @State private var ipv4: String?
    @State private var ipv6: String?

    var body: some View {
        NavigationStack {
            List {
                serverSection
                connectionSection
                credentialsSection
                behaviourSection
                logSection
            }
            .navigationTitle("FTP Server")
            .onAppear {
                porttext = String(port)
                refreshaddresses()
                if password.isEmpty {
                    password = ftpserver.generatepassword()
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
            if !mgr.sbxready {
                Text("Sandbox escape not ready. Run the sandbox escape first.")
                    .foregroundColor(.secondary)
            }

            Label {
                Text("Anyone on the same network who has the password can READ, OVERWRITE and DELETE any file the app can reach. There is no undo.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundColor(.red)

            Toggle("FTP Server", isOn: Binding(
                get: { server.isrunning },
                set: { wanted in
                    if wanted {
                        startserver()
                    } else {
                        server.stop()
                    }
                }
            ))
            .disabled(!mgr.sbxready && !server.isrunning)

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
                Text("Active Client")
                Spacer()
                if server.clientconnected {
                    Text(server.clientlabel.isEmpty ? "connected" : server.clientlabel)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("none")
                        .foregroundColor(.secondary)
                }
            }

            if server.waitingclient {
                HStack {
                    Text("Waiting Client")
                    Spacer()
                    Text("logging in")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }

            if server.clientconnected {
                HStack {
                    Text("Remote Path")
                    Spacer()
                    Text(server.remotepath.isEmpty ? "/" : server.remotepath)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if server.clientconnected || server.waitingclient {
                Button(role: .destructive) {
                    server.disconnectclient()
                } label: {
                    Label("Disconnect Client", systemImage: "xmark.circle")
                }
            }
        } header: {
            HeaderLabel(text: "Server", icon: "network")
        } footer: {
            Text("Full disk file access requires the Sandbox Escape. The server will not start until it is ready. A second client may connect but only replaces the current session after it logs in and the current session is idle; it can never interrupt a transfer.")
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
                TextField("2121", text: $porttext)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospaced()
                    .frame(maxWidth: 90)
            }

            if let address = ipv4 {
                HStack {
                    Text("URL")
                    Spacer()
                    Text("ftp://\(address):\(porttext)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = "ftp://\(address):\(porttext)"
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        } header: {
            HeaderLabel(text: "Connection", icon: "wifi")
        } footer: {
            if ipv4 == nil && ipv6 == nil {
                Text("No network address found. Connect to Wi-Fi first.")
            } else if ipv4 == nil {
                Text("Only an IPv6 address was found. Most clients should use EPSV; PASV needs IPv4.")
            } else {
                Text("Connect with any FTP client using the address above. Transfers use passive mode (PASV/EPSV).")
            }
        }
    }

    private var credentialsSection: some View {
        Section {
            HStack {
                Text("Username")
                Spacer()
                TextField("lara", text: $username)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .monospaced()
            }

            HStack {
                Text("Password")
                Spacer()
                TextField("", text: $password)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .monospaced()
            }

            HStack {
                Button {
                    password = ftpserver.generatepassword()
                } label: {
                    Label("Regenerate Password", systemImage: "arrow.triangle.2.circlepath")
                }

                Spacer()

                Button {
                    UIPasteboard.general.string = password
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(password.isEmpty)
            }

            Toggle("Allow anonymous login", isOn: $allowanonymous)
        } header: {
            HeaderLabel(text: "Credentials", icon: "person.badge.key")
        } footer: {
            if server.isrunning {
                Text("Stop the server to change these settings.")
            } else if password.isEmpty && !allowanonymous {
                Text("The password cannot be empty while anonymous login is disabled.")
            } else {
                Text("Type these into your FTP client. Anonymous login accepts any password.")
            }
        }
        .disabled(server.isrunning)
    }

    private var behaviourSection: some View {
        Section {
            Toggle("Start in /var/mobile", isOn: $startinmobile)
                .disabled(server.isrunning)

            Toggle("Read-only (block uploads, deletes, mkdir/rmdir)", isOn: $readonly)
                .disabled(server.isrunning)

            Toggle("Keep running in background", isOn: $keeprunning)
        } header: {
            HeaderLabel(text: "Behaviour", icon: "gearshape")
        } footer: {
            Text("Start in /var/mobile only selects the folder a new session browses first; it is not a boundary. Clients can still navigate anywhere the Sandbox Escape can reach, including /. Read-only rejects STOR, DELE, MKD and RMD server-side.")
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
        guard mgr.sbxready else {
            server.log("cannot start: sandbox escape not ready")
            return
        }
        guard let value = Int(porttext), value > 0, value <= 65535 else {
            server.log("cannot start: invalid port \"\(porttext)\"")
            return
        }

        port = value
        let startpath = startinmobile ? "/var/mobile" : "/"
        server.start(
            port: UInt16(value),
            startpath: startpath,
            username: username,
            password: password,
            allowanonymous: allowanonymous,
            readonly: readonly
        )
    }
}
