//
//  GlobalPrefsView.swift
//  lara
//
//  global UI preferences pack. writes system-wide UI tweaks into the managed
//  preference plists under /var/Managed Preferences/mobile. every change is
//  backed up to Documents/lara_backups and needs a respring to apply.
//

import SwiftUI
import Foundation

struct GlobalPrefsView: View {
    @ObservedObject var mgr: laramgr

    @State private var isLoading = false

    @State private var interfaceStyle: Int = 0
    @State private var animationCoefficient: Double = 1.0

    @State private var reduceMotion = false
    @State private var reduceTransparency = false
    @State private var increaseContrast = false

    @State private var batteryPercentageAlways = false
    @State private var batteryCondensedForce = false

    @State private var keyboardAutocorrection = false
    @State private var keyboardPrediction = false
    @State private var keyboardAutocapitalization = false
    @State private var keyboardShowPredictionBar = false

    private let uikit = uiprefsdomain.uikit.rawValue
    private let accessibility = uiprefsdomain.accessibility.rawValue
    private let systemstatusui = uiprefsdomain.systemstatusui.rawValue
    private let preferences = uiprefsdomain.preferences.rawValue

    var body: some View {
        List {
            if !canWrite {
                Section {
                    Text("Sandbox escape or VFS is not ready. Run the exploit first.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Picker("Interface Style", selection: Binding(
                    get: { interfaceStyle },
                    set: { applyInterfaceStyle($0) }
                )) {
                    Text("Automatic").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(isLoading || !canWrite)

                Button(role: .destructive) {
                    restoreDefaults(
                        path: uikit,
                        keys: ["UIUserInterfaceStyle"],
                        label: "Interface Style",
                        postdarkmode: true
                    )
                } label: {
                    Text("Restore Defaults")
                }
                .disabled(isLoading || !canWrite)
            } header: {
                HeaderLabel(text: "Interface Style", icon: "circle.lefthalf.filled")
            } footer: {
                Text("Writes UIUserInterfaceStyle to com.apple.UIKit.plist (1 = light, 2 = dark, 0 = automatic), then posts com.apple.darkmode.changed. Respring to apply.")
            }

            Section {
                Toggle("Reduce Motion", isOn: prefToggle(
                    $reduceMotion,
                    path: accessibility,
                    key: "ReduceMotionEnabled",
                    label: "Reduce Motion"
                ))

                Toggle("Reduce Transparency", isOn: prefToggle(
                    $reduceTransparency,
                    path: accessibility,
                    key: "ReduceTransparencyEnabled",
                    label: "Reduce Transparency"
                ))

                Toggle("Increase Contrast", isOn: prefToggle(
                    $increaseContrast,
                    path: accessibility,
                    key: "IncreaseContrastEnabled",
                    label: "Increase Contrast"
                ))

                Button(role: .destructive) {
                    restoreDefaults(
                        path: accessibility,
                        keys: [
                            "ReduceMotionEnabled",
                            "ReduceTransparencyEnabled",
                            "IncreaseContrastEnabled",
                        ],
                        label: "Motion & Transparency"
                    )
                } label: {
                    Text("Restore Defaults")
                }
                .disabled(isLoading || !canWrite)
            } header: {
                HeaderLabel(text: "Motion & Transparency", icon: "accessibility")
            } footer: {
                Text("Writes to com.apple.Accessibility.plist. Respring to apply.")
            }

            Section {
                HStack {
                    Text("Animation Speed")
                    Spacer()
                    Text(String(format: "%.2fx", animationCoefficient))
                        .monospaced()
                        .foregroundColor(.secondary)
                }

                Slider(value: $animationCoefficient, in: 0.25...2.0, step: 0.05)
                    .disabled(isLoading || !canWrite)

                Button {
                    applyAnimationSpeed()
                } label: {
                    Text("Apply Animation Speed")
                }
                .disabled(isLoading || !canWrite)

                Button(role: .destructive) {
                    restoreDefaults(
                        path: uikit,
                        keys: ["UIAnimationDragCoefficient"],
                        label: "Animation Speed"
                    )
                } label: {
                    Text("Restore Defaults")
                }
                .disabled(isLoading || !canWrite)
            } header: {
                HeaderLabel(text: "Animation Speed", icon: "timer")
            } footer: {
                Text("Writes UIAnimationDragCoefficient to com.apple.UIKit.plist. 1.00 is the system default, lower is faster (0.50), higher is slower (2.00). Respring to apply.")
            }

            Section {
                Toggle("Always Show Battery Percentage", isOn: prefToggle(
                    $batteryPercentageAlways,
                    path: systemstatusui,
                    key: "batteryPercentageAlwaysEnabled",
                    label: "Always Show Battery Percentage"
                ))

                Toggle("Force Condensed Percentage", isOn: prefToggle(
                    $batteryCondensedForce,
                    path: systemstatusui,
                    key: "batteryCondensedPercentageForceEnabled",
                    label: "Force Condensed Percentage"
                ))

                Button(role: .destructive) {
                    restoreDefaults(
                        path: systemstatusui,
                        keys: [
                            "batteryPercentageAlwaysEnabled",
                            "batteryCondensedPercentageForceEnabled",
                        ],
                        label: "Battery Percentage"
                    )
                } label: {
                    Text("Restore Defaults")
                }
                .disabled(isLoading || !canWrite)
            } header: {
                HeaderLabel(text: "Battery Percentage", icon: "battery.100")
            } footer: {
                Text("Writes to com.apple.SystemStatusUI.plist. Respring to apply.")
            }

            Section {
                Toggle("Autocorrection", isOn: prefToggle(
                    $keyboardAutocorrection,
                    path: preferences,
                    key: "KeyboardAutocorrection",
                    label: "Keyboard Autocorrection"
                ))

                Toggle("Predictive Text", isOn: prefToggle(
                    $keyboardPrediction,
                    path: preferences,
                    key: "KeyboardPrediction",
                    label: "Predictive Text"
                ))

                Toggle("Auto-Capitalization", isOn: prefToggle(
                    $keyboardAutocapitalization,
                    path: preferences,
                    key: "KeyboardAutocapitalization",
                    label: "Keyboard Auto-Capitalization"
                ))

                Toggle("Show Prediction Bar", isOn: prefToggle(
                    $keyboardShowPredictionBar,
                    path: preferences,
                    key: "KeyboardShowPredictionBar",
                    label: "Keyboard Prediction Bar"
                ))

                Button(role: .destructive) {
                    restoreDefaults(
                        path: preferences,
                        keys: [
                            "KeyboardAutocorrection",
                            "KeyboardPrediction",
                            "KeyboardAutocapitalization",
                            "KeyboardShowPredictionBar",
                        ],
                        label: "Keyboard"
                    )
                } label: {
                    Text("Restore Defaults")
                }
                .disabled(isLoading || !canWrite)
            } header: {
                HeaderLabel(text: "Keyboard (Unverified on iOS 26)", icon: "keyboard")
            } footer: {
                Text("Unverified on iOS 26 — newer keyboards may ignore these keys entirely. Writes to com.apple.Preferences.plist. Respring to apply.")
            }

            Section {
                Button {
                    loadState()
                } label: {
                    if isLoading {
                        HStack {
                            Text("Refreshing...")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Refresh Values")
                    }
                }
                .disabled(isLoading || !canWrite)

                Button {
                    mgr.respring()
                } label: {
                    Text("Respring Now")
                }
            } header: {
                HeaderLabel(text: "Actions", icon: "wrench.and.screwdriver")
            } footer: {
                Text("All values are written to /var/Managed Preferences/mobile and apply after a respring (some may need a reboot). plists are backed up to Documents/lara_backups before the first write, so the earliest known state stays recoverable.")
            }
        }
        .navigationTitle("Global UI Preferences")
        .onAppear {
            loadState()
        }
    }

    private var canWrite: Bool {
        mgr.sbxready || mgr.vfsready
    }

    private func loadState() {
        guard canWrite else { return }

        isLoading = true
        defer { isLoading = false }

        interfaceStyle = uiprefsint(uikit, "UIUserInterfaceStyle", fallback: 0)
        animationCoefficient = Double(uiprefsfloat(uikit, "UIAnimationDragCoefficient", fallback: 1.0))

        reduceMotion = uiprefsbool(accessibility, "ReduceMotionEnabled")
        reduceTransparency = uiprefsbool(accessibility, "ReduceTransparencyEnabled")
        increaseContrast = uiprefsbool(accessibility, "IncreaseContrastEnabled")

        batteryPercentageAlways = uiprefsbool(systemstatusui, "batteryPercentageAlwaysEnabled")
        batteryCondensedForce = uiprefsbool(systemstatusui, "batteryCondensedPercentageForceEnabled")

        keyboardAutocorrection = uiprefsbool(preferences, "KeyboardAutocorrection")
        keyboardPrediction = uiprefsbool(preferences, "KeyboardPrediction")
        keyboardAutocapitalization = uiprefsbool(preferences, "KeyboardAutocapitalization")
        keyboardShowPredictionBar = uiprefsbool(preferences, "KeyboardShowPredictionBar")
    }

    private func applyInterfaceStyle(_ style: Int) {
        guard canWrite else {
            alertFailure("Interface Style", "Sandbox escape or VFS is not ready.")
            return
        }

        isLoading = true
        defer { isLoading = false }

        let result = uiprefswrite(uikit, "UIUserInterfaceStyle", style)
        if result.ok {
            uiprefspostdarkmode()
            interfaceStyle = style
            Alertinator.shared.alert(
                title: "Interface Style Applied",
                body: "UIUserInterfaceStyle = \(style). Respring to apply.",
                actionLabel: "Respring",
                action: { mgr.respring() }
            )
        } else {
            alertFailure("Interface Style", result.message)
            loadState()
        }
    }

    private func applyAnimationSpeed() {
        guard canWrite else {
            alertFailure("Animation Speed", "Sandbox escape or VFS is not ready.")
            return
        }

        isLoading = true
        defer { isLoading = false }

        let result = uiprefswrite(uikit, "UIAnimationDragCoefficient", Float(animationCoefficient))
        if result.ok {
            Alertinator.shared.alert(
                title: "Animation Speed Applied",
                body: String(format: "UIAnimationDragCoefficient = %.2f. Respring to apply.", animationCoefficient),
                actionLabel: "Respring",
                action: { mgr.respring() }
            )
        } else {
            alertFailure("Animation Speed", result.message)
            loadState()
        }
    }

    private func prefToggle(_ state: Binding<Bool>, path: String, key: String, label: String) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue },
            set: { enabled in
                setBoolPref(state, path: path, key: key, label: label, enabled: enabled)
            }
        )
    }

    private func setBoolPref(_ state: Binding<Bool>, path: String, key: String, label: String, enabled: Bool) {
        guard canWrite else {
            alertFailure(label, "Sandbox escape or VFS is not ready.")
            return
        }

        isLoading = true
        defer { isLoading = false }

        let result = uiprefswrite(path, key, enabled)
        if result.ok {
            state.wrappedValue = enabled
            globallogger.log("(uiprefs) \(label) \(enabled ? "enabled" : "disabled")")
        } else {
            alertFailure(label, result.message)
            loadState()
        }
    }

    private func restoreDefaults(path: String, keys: [String], label: String, postdarkmode: Bool = false) {
        guard canWrite else {
            alertFailure(label, "Sandbox escape or VFS is not ready.")
            return
        }

        isLoading = true
        defer { isLoading = false }

        let result = uiprefsrestore(path, keys: keys)
        if result.ok {
            if postdarkmode {
                uiprefspostdarkmode()
            }
            loadState()
            Alertinator.shared.alert(
                title: "\(label) Restored",
                body: "Removed \(keys.count) preference(s). Respring to apply.",
                actionLabel: "Respring",
                action: { mgr.respring() }
            )
        } else {
            alertFailure(label, result.message)
            loadState()
        }
    }

    private func alertFailure(_ label: String, _ message: String) {
        globallogger.log("(uiprefs) \(label) failed: \(message)")
        Alertinator.shared.alert(title: "Failed to Apply \(label)", body: message)
    }
}

#Preview {
    NavigationStack {
        GlobalPrefsView(mgr: laramgr.shared)
    }
}
