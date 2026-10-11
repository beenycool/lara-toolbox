//
//  AirTrollerView.swift
//  lara
//
//  UI for AirTroller: AirDrop discovery + the start → cancel loop.
//
//  All the work lives in AirTrollerManager (Sharing/AirTrollerManager.swift);
//  this file only renders state and fires user actions.
//

import SwiftUI

struct AirTrollerView: View {
    @ObservedObject private var mgr: laramgr
    @StateObject private var manager = AirTrollerManager()

    init(mgr: laramgr = laramgr.shared) {
        self.mgr = mgr
    }

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("AirDrop classes", value: manager.issupported ? "available" : "missing")
                    .foregroundColor(manager.issupported ? .green : .red)
                LabeledContent("State", value: manager.status)
                HStack {
                    Text("Cycles")
                    Spacer()
                    Text("\(manager.cyclecount)")
                        .monospaced()
                        .foregroundColor(.secondary)
                }
                if !manager.payloadpath.isEmpty {
                    Text("payload: \(manager.payloadpath)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Section {
                if manager.isscanning {
                    Button("Stop browsing") {
                        manager.stopscan()
                    }
                } else {
                    Button("Start browsing") {
                        manager.startscan()
                    }
                }
            } header: {
                Text("Discovery")
            } footer: {
                Text("AirDrop must be able to see the device; the target has to be discoverable (Everyone / Contacts-only, Everyone auto-expires after ~10 minutes).")
            }

            Section("Targets") {
                if manager.targets.isEmpty {
                    Text(manager.isscanning ? "No discoverable AirDrop nodes yet." : "Start browsing to find discoverable AirDrop nodes.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(manager.targets) { target in
                        Button {
                            manager.selectedtargetid = target.id
                            mgr.logmsg("(airtroller) selected target \(target.name)")
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: manager.selectedtargetid == target.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(manager.selectedtargetid == target.id ? .accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.name)
                                        .foregroundColor(.primary)
                                    if !target.subtitle.isEmpty {
                                        Text(target.subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if target.isdisabled {
                                    Text("unavailable")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Mode") {
                Picker("Mode", selection: $manager.mode) {
                    Text("Survey").tag(AirTrollerManager.Mode.survey)
                    Text("Troll").tag(AirTrollerManager.Mode.troll)
                }
                .pickerStyle(.segmented)

                Text(manager.mode.summary)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Trigger", selection: $manager.triggerkind) {
                    Text("Delay").tag(AirTrollerManager.TriggerKind.delay)
                    Text("Event").tag(AirTrollerManager.TriggerKind.event)
                }
                .pickerStyle(.segmented)

                if manager.triggerkind == .delay {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Trigger delay")
                            Spacer()
                            Text("\(Int(manager.triggerdelayms)) ms")
                                .monospaced()
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $manager.triggerdelayms, in: 0...2000, step: 50)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Trigger event")
                            Spacer()
                            Text(eventname(manager.triggerevent))
                                .monospaced()
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $manager.triggerevent, in: 0...16, step: 1)
                        Text("SFOperation events cannot be received yet, so this falls back to the \(Int(airtrollerfallbackdelay)) ms delay until it is verified on device.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gap between cycles")
                        Spacer()
                        Text("\(Int(manager.gapms)) ms")
                            .monospaced()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $manager.gapms, in: 0...5000, step: 100)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Max cycles (0 = until stopped)")
                        Spacer()
                        Text(manager.maxcycles == 0 ? "∞" : "\(Int(manager.maxcycles))")
                            .monospaced()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $manager.maxcycles, in: 0...50, step: 1)
                }

                Toggle("pass fromShareSheet: YES", isOn: $manager.fromsharesheet)
                Toggle("attach preview image", isOn: $manager.attachpreviewimage)
                Toggle("survey: replay events", isOn: $manager.replaysyntheticevents)
                Text("fromShareSheet: NO is what the share sheet itself passes and keeps everything inside the node (no picker, no share sheet UI).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Run") {
                HStack(spacing: 12) {
                    Button {
                        manager.start()
                    } label: {
                        Text(manager.isrunning ? "Running…" : "Start")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(manager.isrunning || manager.selectedtarget == nil || !manager.issupported)

                    Button {
                        manager.stop()
                    } label: {
                        Text("Stop")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!manager.isrunning)
                }
            }

            Section {
                HStack {
                    Text("Events")
                    Spacer()
                    if !manager.events.isEmpty {
                        Button("Clear") {
                            manager.events = []
                            mgr.logmsg("(airtroller) event log cleared")
                        }
                        .font(.caption)
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(manager.events) { event in
                                Text("\(event.stamp)  \(event.text)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .id(event.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 180)
                    .onChange(of: manager.events.count) { _ in
                        if let last = manager.events.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How this works")
                        .font(.footnote.weight(.semibold))
                    Text("AirTroller starts an AirDrop transfer to the picked node and cancels it again before the target can accept, so the request flashes up and disappears. The target has to be discoverable (AirDrop on Everyone or Contacts-only, and Everyone auto-expires after ~10 minutes on modern iOS). Your own device shows nothing while it runs, so tell the person first – only use this on someone who is up for the joke.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            manager.startscan()
        }
        .onDisappear {
            manager.stop()
            manager.stopscan()
        }
    }

    private func eventname(_ value: Double) -> String {
        "\(Int(value)) \(AirTrollerBridge.name(forOperationEvent: Int(value)))"
    }
}

private let airtrollerfallbackdelay: Double = 400
