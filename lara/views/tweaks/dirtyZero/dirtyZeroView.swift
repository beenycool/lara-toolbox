//
//  dirtyZeroView.swift
//  lara
//
//  Created by lunginspector on 5/14/26.
//

import SwiftUI

struct dirtyZeroView: View {
    @EnvironmentObject private var mgr: laramgr
    @AppStorage("tweakArray") var tweakArray: [ZeroSection] = TweakArray.tweaks
    @AppStorage("enableRiskyTweaks") var enableRiskyTweaks: Bool = false
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: HeaderLabel(text: "Actions", icon: "wrench.and.screwdriver"), footer: Text("All tweaks are done in memory, so if something goes wrong, please reboot your device. Made with love by [jailbreak.party](https://jailbreak.party). This section of tweaks is also available as a [seperate app!](https://github.com/jailbreakdotparty/dirtyZero)")) {
                    Button("Apply Tweaks", action: {
                        applyTweaks()
                    })
                    Button("Respring", action: {
                        localRespring()
                    })
                    Toggle("Enable Risky Tweaks", isOn: $enableRiskyTweaks)
                }
                
                ListedTweaksSection
            }
            .navigationTitle("dirtyZero")
        }
    }
    
    private var ListedTweaksSection: some View {
        ForEach($tweakArray) { $section in
            if (section.name == "Risky Tweaks" && enableRiskyTweaks) || section.name != "Risky Tweaks" {
                Section(header: HeaderDropdown(text: section.name, icon: section.icon, isExpanded: $section.isExpanded, useItemCount: true, itemCount: section.tweaks.count)) {
                    if section.isExpanded {
                        ForEach($section.tweaks) { $tweak in
                            if (doubleSystemVersion() >= tweak.minSupportedVersion && doubleSystemVersion() <= tweak.maxSupportedVersion) || weonadebugbuild_pjbweouttahereexclamationmark {
                                PlainToggle(
                                    text: tweak.name,
                                    icon: tweak.icon,
                                    infoType: tweak.disabledOnUnsupported ? .warning : .none,
                                    infoTitle: "Unavailable",
                                    infoMessage: "The files this tweak patches were not found on this iOS version, so it was disabled after the last apply.",
                                    isOn: $tweak.isOn
                                )
                                .disabled(tweak.disabledOnUnsupported)
                            }
                        }
                    }
                }
            }
        }
    }
    
    func applyTweaks() {
        var applied = 0
        var skipped = 0
        var failed = 0

        for s in tweakArray.indices {
            for t in tweakArray[s].tweaks.indices {
                guard tweakArray[s].tweaks[t].isOn else { continue }
                let tweak = tweakArray[s].tweaks[t]
                var appliedForTweak = 0
                var existingForTweak = 0

                for path in tweak.paths {
                    // dirtyZero repair: preflight the target (existence + size) so
                    // targets that no longer exist on this iOS version are skipped
                    // and logged instead of being silently attempted.
                    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                    guard let attrs, let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else {
                        skipped += 1
                        mgr.logmsg("(dirtyZero) skipped missing or empty target for '\(tweak.name)': \(path)")
                        continue
                    }

                    existingForTweak += 1
                    mgr.logmsg("(dirtyZero) '\(tweak.name)' -> \(path) (\(size) bytes)")

                    // Note: no byte offsets are documented anywhere in this repo for
                    // these targets, so they are still zeroed whole-file. If exact
                    // offsets are ever documented, use mgr.vfszeroatoffset(...).
                    if mgr.vfszeropage(at: path, dumb: true) {
                        applied += 1
                        appliedForTweak += 1
                    } else {
                        failed += 1
                    }
                }

                let disabled = existingForTweak == 0
                if tweakArray[s].tweaks[t].disabledOnUnsupported != disabled {
                    tweakArray[s].tweaks[t].disabledOnUnsupported = disabled
                }
                if disabled {
                    mgr.logmsg("(dirtyZero) '\(tweak.name)' disabled: no target files exist on this iOS version")
                } else if appliedForTweak == 0 {
                    mgr.logmsg("(dirtyZero) '\(tweak.name)': zeroing failed for every existing target")
                }
            }
        }

        let body = "Applied \(applied) file(s), \(failed) failed, skipped \(skipped) missing/empty file(s).\nZeroing files with DarkSword is finicky, so you may have to apply multiple times!"

        if applied > 0 {
            Alertinator.shared.alert(title: "Attempted to apply all tweaks!", body: body, actionLabel: "Respring", action: {
                localRespring()
            })
        } else {
            Alertinator.shared.alert(title: "Attempted to apply all tweaks!", body: body)
        }
    }

    private func localRespring() {
        // dirtyZero repair: restart SpringBoard locally using the repo's
        // crashproc() primitive (declared in kexploit/utils.h) instead of loading
        // the WebKit respring page that mgr.respring() overlays.
        guard mgr.dsready else {
            mgr.logmsg("(dirtyZero) not respringing: kernel r/w is not ready")
            return
        }

        mgr.logmsg("(dirtyZero) restarting SpringBoard via crashproc()")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            _ = "SpringBoard".withCString { cname in
                crashproc(cname)
            }
        }
    }
}

// allows us to put arrays into AppStorage
extension Array: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else {
            return nil
        }
        self = result
    }
    
    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}
