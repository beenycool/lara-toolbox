//
//  SecurityTogglesView.swift
//  lara
//
//  Kernel security toggles lab (MAC enforcement + AMFI probe/write).
//  DANGEROUS AREA - read docs/dev/security-integration.md before changing anything.
//
//  Design rules for this screen:
//   - everything is gated on mgr.dsready
//   - every destructive action needs a typed confirmation ("RISK" / "ENFORCE")
//   - every write is read back by the ObjC layer and logged via globallogger
//   - defaults stay untouched until the user types the confirmation
//

import SwiftUI

struct amfiprobe: Identifiable {
    let id = UUID()
    let name: String
    let resolved: Bool
    let addr: String
    let value: Int64?
    let verified: Bool
    let note: String
}

private let amfivariablenames = [
    "cs_enforcement_disable",
    "amfi_enforce_launch_constraints",
    "amfi_allow_3p_launch_constraints",
    "amfi_enforce_cc_types",
]

struct SecurityTogglesView: View {
    @ObservedObject private var mgr = laramgr.shared

    // MAC enforcement
    @State private var macsupported: Bool? = nil
    @State private var macvalue: Int64? = nil
    @State private var macpending: Int64? = nil
    @State private var macconfirm: String = ""
    @State private var macbusy = false

    // AMFI probe
    @State private var amfibusy = false
    @State private var amfierror: String? = nil
    @State private var amfiprobes: [amfiprobe] = []

    // AMFI write
    @State private var risktext: String = ""
    @State private var csaddr: String? = nil
    @State private var csvalue: Int64? = nil
    @State private var csverified = false
    @State private var csbaseline: Int64? = nil
    @State private var cspending: Int64? = nil
    @State private var csbusy = false

    private var riskunlocked: Bool {
        risktext.trimmingCharacters(in: .whitespacesAndNewlines) == "RISK"
    }

    private var macrequiredword: String {
        (macpending ?? 1) == 0 ? "RISK" : "ENFORCE"
    }

    private var macconfirmok: Bool {
        macconfirm.trimmingCharacters(in: .whitespacesAndNewlines) == macrequiredword
    }

    var body: some View {
        NavigationStack {
            List {
                if !mgr.dsready {
                    Section {
                        Text("Kernel R/W is not ready. Run the exploit first.")
                            .foregroundColor(.secondary)
                    } header: {
                        Text("Status")
                    }
                }

                macsection
                amfiprobessection
                amfiwritesection
            }
            .navigationTitle("Kernel Security")
        }
        .onAppear {
            if mgr.dsready { refreshmac() }
        }
        .onChange(of: mgr.dsready) { ready in
            if ready {
                refreshmac()
            } else {
                resetall()
            }
        }
        .onChange(of: risktext) { text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == "RISK",
               csvalue == nil,
               mgr.dsready,
               !amfibusy {
                runprobe()
            }
        }
    }

    // MARK: - MAC enforcement

    private var macsection: some View {
        Section {
            HStack {
                Text("security.mac.proc_enforce")
                    .font(.system(.body, design: .monospaced))
                Spacer()
                if macbusy {
                    ProgressView()
                } else if let value = macvalue {
                    Text(value == 0 ? "not enforced" : "enforced")
                        .foregroundColor(value == 0 ? .red : .green)
                        .monospaced()
                } else {
                    Text(macsupported == false ? "unresolved" : "unknown")
                        .foregroundColor(.secondary)
                }
            }

            if let supported = macsupported, !supported {
                Text("mac_proc_enforce could not be resolved on this build. Toggling is unavailable.")
                    .foregroundColor(.secondary)
            }

            if macsupported == true, let current = macvalue {
                Toggle("Disable MAC enforcement (write 0)", isOn: Binding(
                    get: { (macpending ?? current) == 0 },
                    set: { newvalue in
                        macpending = newvalue ? 0 : 1
                        macconfirm = ""
                    }
                ))
                .disabled(macbusy || macpending != nil)

                if let pending = macpending, pending != current {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pending == 0
                             ? "This disables MAC policy enforcement globally until reboot. Type RISK to confirm."
                             : "Type ENFORCE to confirm re-enabling MAC policy enforcement.")
                            .font(.footnote)
                            .foregroundColor(pending == 0 ? .red : .secondary)

                        TextField("Type \(macrequiredword)", text: $macconfirm)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .monospaced()

                        HStack {
                            Button("Cancel") {
                                macpending = nil
                                macconfirm = ""
                            }
                            Spacer()
                            Button("Apply") {
                                applymac(pending)
                            }
                            .disabled(!macconfirmok || macbusy)
                            .foregroundColor(.red)
                        }
                    }
                }
            }

            if macsupported == true, let current = macvalue, current == 0 {
                Button("Revert (re-enforce)") {
                    macpending = 1
                    macconfirm = ""
                }
                .disabled(macbusy || macpending != nil)
                .foregroundColor(.green)
            }
        } header: {
            Text("MAC Enforcement")
        } footer: {
            Text("Writes the kernel variable mac_proc_enforce (security.mac.proc_enforce). Disabling weakens MAC policy enforcement globally until reboot; reboot restores the boot default. Every write is read back and logged.")
        }
    }

    // MARK: - AMFI probe

    private var amfiprobessection: some View {
        Section {
            Button {
                runprobe()
            } label: {
                HStack {
                    Text("Run AMFI probe (read-only)")
                    Spacer()
                    if amfibusy { ProgressView() }
                }
            }
            .disabled(!mgr.dsready || amfibusy)

            if let error = amfierror {
                Text(error)
                    .foregroundColor(.red)
            }

            ForEach(amfiprobes) { probe in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(probe.name)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(probe.resolved ? "resolved" : "unresolved")
                            .font(.caption)
                            .foregroundColor(probe.resolved ? .green : .secondary)
                    }

                    HStack {
                        Text(probe.addr.isEmpty ? "-" : probe.addr)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        if let value = probe.value {
                            Text("value: \(value)")
                                .font(.system(.caption2, design: .monospaced))
                        }
                    }

                    Text(probe.note)
                        .font(.caption2)
                        .foregroundColor(probe.verified ? .green : .orange)
                }
            }
        } header: {
            Text("AMFI Probe")
        } footer: {
            Text("Read-only. Resolves each AMFI boot-arg variable through the kernelcache patchfinder and reads the current 32-bit value. Resolution is best-effort: these variables are boot-arg targets, so a heuristic address can point at a related field.")
        }
    }

    // MARK: - AMFI write

    private var amfiwritesection: some View {
        Section {
            Text("DANGER: writing cs_enforcement_disable can break code signing enforcement system-wide. Apps may fail to launch and the device may become unstable. Only continue if you understand the risk. Revert by writing the original value back, or reboot.")
                .font(.footnote)
                .foregroundColor(.red)

            HStack {
                Text("cs_enforcement_disable")
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Text(csaddr ?? "unresolved")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("current value:")
                Spacer()
                Text(csvalue.map { "\($0)" } ?? "unknown")
                    .monospaced()
                    .foregroundColor(csvalue == 1 ? .red : .secondary)
                if csvalue != nil && !csverified {
                    Text("heuristic")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            TextField("Type RISK to unlock", text: $risktext)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .monospaced()
                .foregroundColor(riskunlocked ? .green : .red)

            if riskunlocked {
                if let current = csvalue, csverified {
                    Toggle("Disable code signing enforcement (write 1)", isOn: Binding(
                        get: { (cspending ?? current) == 1 },
                        set: { newvalue in cspending = newvalue ? 1 : 0 }
                    ))
                    .disabled(csbusy)

                    HStack {
                        Button("Write \(cspending ?? current)") {
                            applycs(cspending ?? current)
                        }
                        .disabled(csbusy || (cspending ?? current) == current)
                        .foregroundColor(.red)

                        Spacer()

                        if let baseline = csbaseline, baseline != current {
                            Button("Restore \(baseline)") {
                                applycs(baseline)
                            }
                            .disabled(csbusy)
                            .foregroundColor(.green)
                        }
                    }
                } else if csvalue != nil {
                    Text("Writes are blocked: cs_enforcement_disable resolved heuristically, not section-verified, so the address cannot be trusted for a write.")
                        .font(.footnote)
                        .foregroundColor(.orange)
                } else {
                    Text("cs_enforcement_disable is unresolved on this build; writes are refused.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("AMFI Write")
        } footer: {
            Text("Single variable only: cs_enforcement_disable (0 = enforcement on, 1 = enforcement disabled). Writes are blocked unless the address is section-verified; heuristic candidates are refused. Every write is read back and logged.")
        }
    }

    // MARK: - actions

    private func refreshmac() {
        guard mgr.dsready, !macbusy else { return }
        macbusy = true
        globallogger.log("(sec) resolving security.mac.proc_enforce...")
        DispatchQueue.global(qos: .userInitiated).async {
            let supported = sec_proc_enforce_supported()
            var value: Int64? = nil
            if supported {
                let read = sec_get_proc_enforce()
                if read >= 0 { value = Int64(read) }
            }
            DispatchQueue.main.async {
                macbusy = false
                macsupported = supported
                macvalue = value
                macpending = nil
                macconfirm = ""
                if supported, let value = value {
                    globallogger.log("(sec) mac_proc_enforce = \(value) (\(value == 0 ? "not enforced" : "enforced"))")
                } else {
                    globallogger.log("(sec) mac_proc_enforce unresolved on this build")
                }
            }
        }
    }

    private func applymac(_ value: Int64) {
        guard mgr.dsready, !macbusy, macconfirmok else { return }
        macbusy = true
        globallogger.log("(sec) writing mac_proc_enforce = \(value) (confirmed with \(macrequiredword))")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = sec_set_proc_enforce(Int(value))
            var newvalue: Int64? = nil
            if ok {
                let read = sec_get_proc_enforce()
                if read >= 0 { newvalue = Int64(read) }
            }
            DispatchQueue.main.async {
                macbusy = false
                macpending = nil
                macconfirm = ""
                if ok {
                    macvalue = newvalue ?? value
                    globallogger.log("(sec) mac_proc_enforce write ok, now \(macvalue ?? value)")
                } else {
                    globallogger.log("(sec) mac_proc_enforce write FAILED (see logs)")
                }
            }
        }
    }

    private func runprobe() {
        guard mgr.dsready, !amfibusy else { return }
        amfibusy = true
        amfierror = nil
        globallogger.log("(sec) running AMFI probe (read-only)...")
        DispatchQueue.global(qos: .userInitiated).async {
            let rawdict = sec_amfi_probe()
            var rows: [amfiprobe] = []
            var error: String? = nil
            var cs: (addr: String, value: Int64, verified: Bool)? = nil

            if let dict = rawdict as? [String: Any] {
                if let e = dict["error"] as? String {
                    error = e
                } else {
                    for name in amfivariablenames {
                        guard let entry = dict[name] as? [String: Any] else { continue }
                        let resolved = ((entry["resolved"] as? NSNumber)?.boolValue) ?? false
                        let addr = (entry["addr"] as? String) ?? ""
                        let value = (entry["value"] as? NSNumber)?.int64Value
                        let verified = ((entry["verified"] as? NSNumber)?.boolValue) ?? false
                        let note = (entry["note"] as? String) ?? ""
                        rows.append(amfiprobe(name: name, resolved: resolved, addr: addr, value: value, verified: verified, note: note))
                        if name == "cs_enforcement_disable", resolved, let value = value {
                            cs = (addr, value, verified)
                        }
                    }
                }
            } else {
                error = "probe failed"
            }

            DispatchQueue.main.async {
                amfibusy = false
                amfierror = error
                if !rows.isEmpty { amfiprobes = rows }
                if let cs = cs {
                    if csbaseline == nil { csbaseline = cs.value }
                    csaddr = cs.addr
                    csvalue = cs.value
                    csverified = cs.verified
                    cspending = nil
                    globallogger.log("(sec) AMFI probe: cs_enforcement_disable @ \(cs.addr) = \(cs.value)\(cs.verified ? "" : " (heuristic)")")
                }
                if let error = error {
                    globallogger.log("(sec) AMFI probe failed: \(error)")
                } else {
                    globallogger.log("(sec) AMFI probe done (\(rows.count) variables)")
                }
            }
        }
    }

    private func applycs(_ value: Int64) {
        guard mgr.dsready, riskunlocked, !csbusy else { return }
        csbusy = true
        globallogger.log("(sec) AMFI write: cs_enforcement_disable = \(value) (RISK confirmed)")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = sec_amfi_write("cs_enforcement_disable", Int(value))
            DispatchQueue.main.async {
                csbusy = false
                cspending = nil
                if ok {
                    csvalue = value
                    // Re-arm the typed confirmation: a second write needs RISK again.
                    risktext = ""
                    globallogger.log("(sec) AMFI write ok, cs_enforcement_disable = \(value) (read back verified)")
                } else {
                    globallogger.log("(sec) AMFI write FAILED/refused (see logs)")
                }
            }
        }
    }

    private func resetall() {
        macsupported = nil
        macvalue = nil
        macpending = nil
        macconfirm = ""
        amfiprobes = []
        amfierror = nil
        risktext = ""
        csaddr = nil
        csvalue = nil
        csverified = false
        csbaseline = nil
        cspending = nil
    }
}
