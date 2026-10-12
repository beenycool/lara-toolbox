//
//  AirTrollerView.swift
//  lara
//
//  Minimal UI for AirTroller: browse → tap a name → Survey or Troll.
//  Every knob lives under "Advanced"; the log is collapsed by default.
//  All the work lives in AirTrollerManager (Sharing/AirTrollerManager.swift).
//

import SwiftUI

struct AirTrollerView: View {
    @ObservedObject private var mgr: laramgr
    @ObservedObject private var manager = AirTrollerManager.shared

    @State private var showadvanced = false
    @State private var showlog = false

    init(mgr: laramgr = laramgr.shared) {
        self.mgr = mgr
    }

    var body: some View {
        List {
            browseSection
            targetsSection
            if manager.selectedtarget != nil {
                actionSection
            }
            advancedSection
            logSection
        }
        .navigationTitle("AirTroller")
        .onAppear { manager.startscan() }
        .onDisappear { manager.stop() }   // keep discovery alive across view churn
    }

    // MARK: browse

    private var browseSection: some View {
        Section {
            Button {
                manager.isscanning ? manager.stopscan() : manager.startscan()
            } label: {
                HStack {
                    Image(systemName: manager.isscanning ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
                    Text(manager.isscanning ? "Stop browsing" : "Start browsing")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!manager.issupported)

            HStack {
                Text(manager.status)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                if manager.isrunning {
                    Text("cycles \(manager.cyclecount)")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        } footer: {
            Text("Turn AirDrop on (Contacts Only or Everyone) and give it ~10 seconds to find nearby devices.")
        }
    }

    // MARK: targets

    private var targetsSection: some View {
        Section("Nearby") {
            if !manager.issupported {
                Text("AirDrop is unavailable on this build.").foregroundColor(.red)
            } else if manager.targets.isEmpty {
                Text(manager.isscanning ? "Searching…" : "Tap Start browsing to look for devices.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(manager.targets) { target in
                    Button {
                        manager.selectedtargetid = target.id
                    } label: {
                        HStack {
                            Image(systemName: manager.selectedtargetid == target.id ? "checkmark.circle.fill" : "circle")
                            Text(target.name).foregroundColor(.primary)
                            Spacer()
                            if target.isdisabled {
                                Text("unavailable").font(.caption).foregroundColor(.orange)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: actions

    private var actionSection: some View {
        Section {
            if manager.isrunning {
                Button {
                    manager.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    manager.mode = .survey
                    manager.start()
                } label: {
                    Label("Survey (one send, log events)", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    manager.mode = .troll
                    manager.start()
                } label: {
                    Label("Troll", systemImage: "repeat")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
            }
        } header: {
            Text(manager.selectedtarget.map { "Target: \($0.name)" } ?? "Target")
        }
    }

    // MARK: advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showadvanced) {
                Picker("Trigger", selection: $manager.triggerkind) {
                    Text("Delay").tag(AirTrollerManager.TriggerKind.delay)
                    Text("Event").tag(AirTrollerManager.TriggerKind.event)
                }
                .pickerStyle(.segmented)

                if manager.triggerkind == .delay {
                    slider("Trigger delay", value: $manager.triggerdelayms, range: 0...2000, step: 50, unit: "ms")
                } else {
                    slider("Trigger event", value: $manager.triggerevent, range: 0...16, step: 1, unit: "")
                    Text("Live events aren't reachable yet, so this uses a \(Int(airtrollerfallbackdelay)) ms delay until the survey confirms the right event.")
                        .font(.caption).foregroundColor(.secondary)
                }

                slider("Gap between cycles", value: $manager.gapms, range: 0...5000, step: 100, unit: "ms")
                slider("Max cycles (0 = until stopped)", value: $manager.maxcycles, range: 0...50, step: 1, unit: "")

                Toggle("Pass fromShareSheet: YES", isOn: $manager.fromsharesheet)
                Toggle("Attach preview image", isOn: $manager.attachpreviewimage)
                Toggle("Survey: replay events", isOn: $manager.replaysyntheticevents)

                Divider()

                Button {
                    manager.diagnose()
                } label: {
                    Label("Diagnose mach + sandbox", systemImage: "stethoscope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("Borrow another process's sandbox object — a valid pointer, unlike the earlier NULL attempt that respringed, but still kernel surgery:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Button("adopt: sharingd") { manager.adoptfrom(name: "sharingd") }
                        .buttonStyle(.bordered)
                    Button("adopt: SpringBoard") { manager.adoptfrom(name: "SpringBoard") }
                        .buttonStyle(.bordered)
                }
            }
        } footer: {
            Text("Only use this on someone who is up for the joke — the target's AirDrop prompt flashes up and disappears.")
        }
    }

    // MARK: log

    private var logSection: some View {
        Section {
            DisclosureGroup("Log (\(manager.events.count))", isExpanded: $showlog) {
                if manager.events.isEmpty {
                    Text("No events yet.").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(manager.events.suffix(60)) { event in
                        Text("\(event.stamp)  \(event.text)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: helpers

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        step: Double,
                        unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(unit.isEmpty ? "\(Int(value.wrappedValue))" : "\(Int(value.wrappedValue)) \(unit)")
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

private let airtrollerfallbackdelay: Double = 400
