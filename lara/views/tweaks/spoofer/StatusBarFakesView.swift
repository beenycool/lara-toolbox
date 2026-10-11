//
//  StatusBarFakesView.swift
//  lara
//
//  Device & Status Spoofer.
//
//  Section 1 - Fake status bar:
//    Battery percentage/charging, Wi-Fi bars, cellular bars, carrier text and
//    a fake clock, applied live in SpringBoard through the existing RemoteCall
//    primitive (mgr.sbProc). The remote calls mirror the proven pattern in
//    lara/kexploit/pe/rc.m: status_bar_time_format() (~line 44) and the
//    sibling views/tweaks/StatusBarStudioView.swift helpers.
//
//    Persistence: +[SBSystemStatusStatusBarOverridesArchiver _archiveFileURL]
//    is called to discover SpringBoard's own override archive file. The file
//    is backed up to Documents/lara_backups before it is touched and can be
//    restored/removed from this screen. Apply additionally probes the private
//    archiver/record/publisher objects, every selector is gated with
//    respondsToSelector: and every miss is logged instead of crashing.
//
//  Section 2 - iOS version spoof:
//    BuildVersion/ProductVersion (and read-only friends) from the
//    MobileGestalt cache, implemented in lara/funcs/mgspoof.swift.
//
//  See docs/dev/spoofer-integration.md for the selector inventory,
//  verification status and risk notes.
//

import SwiftUI

struct StatusBarFakesView: View {
    @ObservedObject var mgr: laramgr

    // MARK: - Fake status bar state

    @State private var batteryEnabled: Bool = true
    @State private var batteryPercentage: Double = 100
    @State private var batteryCharging: Bool = true
    @State private var wifiBars: Int = 3
    @State private var cellularBars: Int = 4
    @State private var carrierText: String = ""
    @State private var overrideTimeText: String = ""
    @State private var archivePath: String = ""
    @State private var backupPath: String = ""
    @State private var confirmRemoveArchive: Bool = false

    // MARK: - Version spoof state

    @State private var mgValues: [String: String] = [:]
    @State private var mgRealValues: [String: String] = [:]
    @State private var mgUnmapped: [String] = []
    @State private var mgReadMessage: String = ""
    @State private var newBuildVersion: String = ""
    @State private var newProductVersion: String = ""

    // MARK: - Shared run state

    @State private var running: Bool = false
    @State private var lastAction: String = ""
    @State private var lastResult: String = ""

    var body: some View {
        List {
            remoteCallSection
            batterySection
            signalSection
            carrierTimeSection
            applySection
            archiveSection
            fakeWarningSection
            versionSpoofSection
            versionWarningSection
            lastResultSection
        }
        .navigationTitle(Text("Device & Status Spoofer"))
        .onAppear {
            loadVersionValues()
        }
        .alert("Remove override archive?", isPresented: $confirmRemoveArchive) {
            Button("Remove", role: .destructive) {
                let path = archivePath
                run("Remove Override Archive", prefix: "(spoof)", work: { self.removeArchive(path: path) }, onComplete: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the discovered archive file, or truncates it to 0 bytes if deletion fails. SpringBoard treats an empty/invalid record as a reset and falls back to factory status bar values. A respring may be needed.")
        }
    }

    // MARK: - RemoteCall status

    private var remoteCallSection: some View {
        Section {
            HStack {
                Text("RemoteCall")
                Spacer()
                if mgr.rcready {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                    Text("Ready")
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.red)
                    Text("Not initialized")
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("SpringBoard process")
                Spacer()
                Text(mgr.sbProc != nil ? "bound" : "missing")
                    .foregroundColor(.secondary)
            }

            if let error = mgr.sbProc?.lastError, !error.isEmpty {
                Text("Last RemoteCall error: \(error)")
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            if !archivePath.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Override archive")
                        .foregroundColor(.secondary)
                    Text(archivePath)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Button {
                run("Discover Override Archive", prefix: "(spoof)", work: { self.discoverArchive() }, onComplete: nil)
            } label: {
                Text("Discover override archive path")
            }
            .disabled(!mgr.rcready || running)
        } header: {
            HeaderLabel(text: "RemoteCall Status", icon: "syringe")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !mgr.rcready {
                    Text("RemoteCall is not initialized. How are you here?")
                    Text("Run the exploit first, then tap Initialize RemoteCall on the main screen (RemoteCall section) to bind to SpringBoard before using this screen.")
                }
                Text("RemoteCall is relatively unstable and may not work properly.")
            }
        }
    }

    // MARK: - Battery

    private var batterySection: some View {
        Section {
            Toggle("Override battery percentage", isOn: $batteryEnabled)

            HStack {
                Text("Percentage")
                Spacer()
                Text("\(Int(batteryPercentage))%")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $batteryPercentage, in: 0...100, step: 1)
                .disabled(!batteryEnabled)

            Toggle("Fake charging", isOn: $batteryCharging)
        } header: {
            Text("Battery")
        } footer: {
            Text("Best-effort: probes setBatteryPercentage: and setBatteryCharging: / setCharging: / setBatteryIsCharging: / setIsCharging: on the record, archiver, aggregator and domain-data targets. Values are passed as NSNumber; missing selectors are logged and skipped.")
        }
        .disabled(running)
    }

    // MARK: - Signal bars

    private var signalSection: some View {
        Section {
            Stepper(value: $wifiBars, in: 0...3) {
                HStack {
                    Text("Wi-Fi bars")
                    Spacer()
                    Text("\(wifiBars)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            Stepper(value: $cellularBars, in: 0...4) {
                HStack {
                    Text("Cellular bars")
                    Spacer()
                    Text("\(cellularBars)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Signal Bars")
        } footer: {
            Text("Best-effort: probes setWifiBars: / setWiFiBars: (0-3) and setCellularBars: (0-4). No Wi-Fi/cellular setter was verified on iOS 26, so these stay gated by respondsToSelector: and are reported as missing when absent.")
        }
        .disabled(running)
    }

    // MARK: - Carrier and time

    private var carrierTimeSection: some View {
        Section {
            TextField("Carrier text (e.g. lara)", text: $carrierText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: carrierText) { newValue in
                    if newValue.count > 64 {
                        carrierText = String(newValue.prefix(64))
                    }
                }

            TextField("Override time (e.g. 09:41)", text: $overrideTimeText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: overrideTimeText) { newValue in
                    if newValue.count > 32 {
                        overrideTimeText = String(newValue.prefix(32))
                    }
                }
        } header: {
            Text("Carrier & Time")
        } footer: {
            Text("Carrier uses setCarrierName: (best-effort). Time uses setOverrideTime: with an NSString. advanceOverrideDateByAmount: is not callable through remote_msg (a scalar double would land in the wrong register), so it is intentionally never sent. Status Bar Studio already covers setUserNameOverride:; this screen does not duplicate it.")
        }
        .disabled(running)
    }

    // MARK: - Apply / clear

    private var applySection: some View {
        Section {
            Button {
                let settings = currentFakeSettings()
                run("Apply Fake Status Bar", prefix: "(spoof)", work: { self.applyFakes(settings) }, onComplete: { message in
                    if message.hasPrefix("apply -> set:"), !message.contains("failed"), !message.contains("set: nothing") {
                        Alertinator.shared.alert(
                            title: "Fake Status Bar Applied",
                            body: message + "\n\nOverrides are live in SpringBoard. They are volatile: a respring can drop them unless the archive was persisted. Re-apply after respring if needed.",
                            actionLabel: "Respring",
                            action: { self.mgr.respring() }
                        )
                    }
                })
            } label: {
                Text("Apply fake overrides")
            }
            .disabled(!mgr.rcready || running)

            Button {
                run("Clear Fake Status Bar", prefix: "(spoof)", work: { self.clearFakes() }, onComplete: { message in
                    if message.hasPrefix("clear ->"), !message.contains("failed") {
                        Alertinator.shared.alert(
                            title: "Overrides Cleared",
                            body: message + "\n\nA respring may be needed if anything still shows the old values.",
                            actionLabel: "Respring",
                            action: { self.mgr.respring() }
                        )
                    }
                })
            } label: {
                Text("Clear all overrides")
            }
            .disabled(!mgr.rcready || running)
        } header: {
            Text("Apply / Clear")
        } footer: {
            Text("Apply resolves the archive record, archiver instance, SBStatusBarStateAggregator and a fresh STMutableStatusBarOverridesStatusDomainData, sets each value on the first target that implements the setter, then attempts _queue_persistUpdatedArchiveRecord: / _queue_writeOutArchiveRecord: / _queue_setupObservingAndReconcileInitialState / _sbApplySystemStatusStatusBarOverridesArchiveRecord: and the domain publisher updateData:. Every call is gated with respondsToSelector: and every miss is logged. Clear sends nil/0 values (empty string for carrier) and persists the empty state.")
        }
    }

    // MARK: - Archive backup / restore

    private var archiveSection: some View {
        Section {
            if archivePath.isEmpty {
                Text("Archive path not discovered yet. Tap Discover in the RemoteCall Status section first.")
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Discovered path")
                        .foregroundColor(.secondary)
                    Text(archivePath)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Button {
                let path = archivePath
                run("Backup Override Archive", prefix: "(spoof)", work: { self.backupArchive(path: path) }, onComplete: nil)
            } label: {
                Text("Backup override archive")
            }
            .disabled(archivePath.isEmpty || running)

            if !backupPath.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session backup")
                        .foregroundColor(.secondary)
                    Text(backupPath)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Button {
                let path = archivePath
                let backup = backupPath
                run("Restore Override Archive", prefix: "(spoof)", work: { self.restoreArchive(path: path, backup: backup) }, onComplete: nil)
            } label: {
                Text("Restore archive from session backup")
            }
            .disabled(archivePath.isEmpty || backupPath.isEmpty || running)

            Button(role: .destructive) {
                confirmRemoveArchive = true
            } label: {
                Text("Remove override archive file")
            }
            .disabled(archivePath.isEmpty || running)
        } header: {
            Text("Override Archive Backup")
        } footer: {
            Text("The archive file is SpringBoard's persistence layer for status bar overrides, discovered at runtime through +[SBSystemStatusStatusBarOverridesArchiver _archiveFileURL]. A copy is written to Documents/lara_backups before it is touched. Restore overwrites the live archive from the session copy; Remove deletes or truncates it so SpringBoard falls back to factory values.")
        }
    }

    // MARK: - Fake status bar warning

    private var fakeWarningSection: some View {
        Section {
            Label {
                Text("Overrides are applied live through RemoteCall and are volatile: a respring or SpringBoard restart can drop them. If the archive was successfully persisted they may come back; otherwise re-apply.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }

            Label {
                Text("RemoteCall hijacks a live SpringBoard thread and is unstable. Worst case is a wedged or crashed SpringBoard, which needs a respring (or reboot) to recover.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        } header: {
            Text("Warning")
        }
    }

    // MARK: - Version spoof

    private var versionSpoofSection: some View {
        Section {
            ForEach(mgspoofreadkeys, id: \.self) { key in
                HStack {
                    Text(key)
                    if key == "OSVersion" {
                        Text("(alias)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(mgValues[key] ?? "not cached")
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            if mgReadMessage != "ok" {
                Text("MobileGestalt cache: \(mgReadMessage)")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }

            if !mgRealValues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Device truth (not affected by this spoof)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("kern.osversion \(mgRealValues["BuildVersion"] ?? "?") / ProcessInfo \(mgRealValues["ProductVersion"] ?? "?")")
                        .font(.system(.footnote, design: .monospaced))
                }
            }

            if !mgUnmapped.isEmpty {
                Text("Read-only for: \(mgUnmapped.joined(separator: ", ")) (no CacheExtra slot mapped)")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }

            TextField("New BuildVersion (e.g. 23A341)", text: $newBuildVersion)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !newBuildVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let error = mgspoofvalidatebuildversion(newBuildVersion) {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            TextField("New ProductVersion (e.g. 26.0)", text: $newProductVersion)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !newProductVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let error = mgspoofvalidateproductversion(newProductVersion) {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            Button {
                let build = newBuildVersion
                let product = newProductVersion
                run("Apply Version Spoof", prefix: "(mgspoof)", work: {
                    let result = mgspoofapply(buildVersion: build, productVersion: product)
                    return result.ok ? "apply -> ok (\(result.message))" : "apply -> failed (\(result.message))"
                }, onComplete: { message in
                    if message.hasPrefix("apply -> ok") {
                        Alertinator.shared.alert(
                            title: "Version Spoof Written",
                            body: message + "\n\nRespring (or reboot) to let system components pick up the new values. kern.osversion readers are unaffected and still see the real build.",
                            actionLabel: "Respring",
                            action: { self.mgr.respring() }
                        )
                        self.loadVersionValues()
                    }
                })
            } label: {
                Text("Apply version spoof")
            }
            .disabled(!canApplyVersionSpoof)

            Button {
                run("Revert Version Spoof", prefix: "(mgspoof)", work: {
                    let result = mgspoofrevert()
                    return result.ok ? "revert -> ok (\(result.message))" : "revert -> failed (\(result.message))"
                }, onComplete: { message in
                    if message.hasPrefix("revert -> ok") {
                        Alertinator.shared.alert(
                            title: "Version Spoof Reverted",
                            body: message + "\n\nRespring to let system components pick up the change.",
                            actionLabel: "Respring",
                            action: { self.mgr.respring() }
                        )
                        self.loadVersionValues()
                    }
                })
            } label: {
                Text("Revert (remove spoofed keys)")
            }
            .disabled(!mgr.sbxready || running)

            Button {
                run("Restore MG Backup", prefix: "(mgspoof)", work: {
                    let result = mgspoofrestorebackup()
                    return result.ok ? "restore -> ok (\(result.message))" : "restore -> failed (\(result.message))"
                }, onComplete: { message in
                    if message.hasPrefix("restore -> ok") {
                        Alertinator.shared.alert(
                            title: "MobileGestalt Restored",
                            body: message + "\n\nThis also undoes any other MobileGestalt edits made after that backup. Respring to apply.",
                            actionLabel: "Respring",
                            action: { self.mgr.respring() }
                        )
                        self.loadVersionValues()
                    }
                })
            } label: {
                Text("Restore MG cache from latest backup")
            }
            .disabled(!mgr.sbxready || running)

            Button {
                loadVersionValues()
            } label: {
                Text("Refresh current values")
            }
            .disabled(running)
        } header: {
            HeaderLabel(text: "iOS Version Spoof (MobileGestalt)", icon: "number")
        } footer: {
            Text("Writes BuildVersion/ProductVersion into CacheExtra of the MobileGestalt cache after a timestamped backup. It is read-modify-write with plist validation and requires the sandbox escape. A respring or reboot is needed for components to pick the values up.")
        }
    }

    // MARK: - Version spoof warning

    private var versionWarningSection: some View {
        Section {
            Label {
                Text("Version spoofing can break system components that trust these values: OTA/update checks, App Store and eligibility flows, Settings > General > About mismatches, and other version-gated behavior. Treat it as experimental.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }

            Label {
                Text("Tools that read kern.osversion (sysctl) or the sealed /System/Library/CoreServices/SystemVersion.plist are NOT affected and still see the real version. The MobileGestalt cache only fools components that go through MGCopyAnswer.")
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.orange)
            }

            Label {
                Text("Every write is backed up to Documents/lara_backups first. Revert removes the spoofed keys; Restore rolls the whole cache back to the latest backup.")
            } icon: {
                Image(systemName: "externaldrive.fill")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Version Spoof Warning")
        }
    }

    // MARK: - Last result

    private var lastResultSection: some View {
        Section {
            if lastResult.isEmpty {
                Text("Nothing has been run from this screen yet.")
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lastAction)
                        .foregroundColor(.secondary)
                    Text(lastResult)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Last Result")
        } footer: {
            Text("Status bar overrides live in SpringBoard memory and may not survive a respring; version spoofs live in the MobileGestalt cache file and survive until reverted.")
        }
    }

    // MARK: - Computed state

    private var mgReadOnly: Bool {
        mgReadMessage != "ok" ||
            mgUnmapped.contains("BuildVersion") ||
            mgUnmapped.contains("ProductVersion")
    }

    private var canApplyVersionSpoof: Bool {
        guard !running, mgr.sbxready, !mgReadOnly else { return false }
        guard !newBuildVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !newProductVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return mgspoofvalidatebuildversion(newBuildVersion) == nil &&
            mgspoofvalidateproductversion(newProductVersion) == nil
    }

    // MARK: - Run helper

    /// Runs `work` on a background queue (same shape as RemoteView.run /
    /// StatusBarStudioView.run) and mirrors the result to the log.
    private func run(_ name: String, prefix: String, work: @escaping () -> String, onComplete: ((String) -> Void)?) {
        guard !running else { return }
        running = true
        mgr.logmsg("\(prefix) \(name)...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.mgr.logmsg("\(prefix) \(result)")
                self.lastAction = name
                self.lastResult = result
                onComplete?(result)
                if self.isFailure(result) {
                    Alertinator.shared.alert(title: "\(name) Failed", body: result)
                }
                self.running = false
            }
        }
    }

    private func isFailure(_ result: String) -> Bool {
        let lowercased = result.lowercased()
        return lowercased.contains("-> failed") ||
            lowercased.contains(": failed") ||
            lowercased.contains("failed to")
    }

    // MARK: - Fake settings snapshot

    private struct fakeSettings {
        var batteryEnabled: Bool
        var batteryPercentage: Int
        var batteryCharging: Bool
        var wifiBars: Int
        var cellularBars: Int
        var carrierText: String
        var overrideTimeText: String
    }

    /// Snapshots @State on the main thread so the background work never reads
    /// SwiftUI state directly.
    private func currentFakeSettings() -> fakeSettings {
        fakeSettings(
            batteryEnabled: batteryEnabled,
            batteryPercentage: Int(batteryPercentage.rounded()),
            batteryCharging: batteryCharging,
            wifiBars: wifiBars,
            cellularBars: cellularBars,
            carrierText: carrierText.trimmingCharacters(in: .whitespacesAndNewlines),
            overrideTimeText: overrideTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - RemoteCall bridge
    //
    // The C helpers (remote_sel / remote_msg / remote_getClass / remote_NSString
    // / remote_alloc_str) come from RemoteCall.h, imported by
    // lara-Bridging-Header.h, and are the same helpers rc.m and
    // StatusBarStudioView use. Everything runs inside SpringBoard.

    /// [[UIApplication sharedApplication] statusBarStateAggregator], the proven
    /// lookup from rc.m's status_bar_time_format().
    private func rcStatusBarAggregator(_ proc: RemoteCall) -> UInt64 {
        let uiAppClass = remote_getClass(proc, "UIApplication")
        guard uiAppClass != 0 else { return 0 }

        let selSharedApplication = remote_sel(proc, "sharedApplication")
        let app = remote_msg(proc, uiAppClass, selSharedApplication, 0, 0, 0, 0)
        guard app != 0 else { return 0 }

        let selAggregator = remote_sel(proc, "statusBarStateAggregator")
        guard rcResponds(proc, app, selAggregator) else { return 0 }
        return remote_msg(proc, app, selAggregator, 0, 0, 0, 0)
    }

    /// Asks the remote object before sending a private selector; an unrecognized
    /// selector would raise inside SpringBoard and take it down.
    private func rcResponds(_ proc: RemoteCall, _ object: UInt64, _ selector: UInt64) -> Bool {
        guard object != 0, selector != 0 else { return false }
        let selResponds = remote_sel(proc, "respondsToSelector:")
        return remote_msg(proc, object, selResponds, selector, 0, 0, 0) != 0
    }

    /// Queues a zero-argument selector on SpringBoard's main thread, mirroring
    /// rc.m (performSelectorOnMainThread:withObject:waitUntilDone: NO).
    private func rcDispatch(_ proc: RemoteCall, target: UInt64, selector: UInt64) {
        let selPerform = remote_sel(proc, "performSelectorOnMainThread:withObject:waitUntilDone:")
        remote_msg(proc, target, selPerform, selector, 0, 0, 0)
    }

    /// Dispatches every selector the target responds to and reports the misses.
    private func rcDispatchUpdates(_ proc: RemoteCall, aggregator: UInt64,
                                   selectors: [String]) -> (performed: [String], missing: [String]) {
        var performed: [String] = []
        var missing: [String] = []

        for name in selectors {
            let selector = remote_sel(proc, name)
            if rcResponds(proc, aggregator, selector) {
                rcDispatch(proc, target: aggregator, selector: selector)
                performed.append(name)
            } else {
                missing.append(name)
            }
        }

        return (performed, missing)
    }

    /// Creates an NSString in the remote process, same fallback split as
    /// StatusBarStudioView (ASCII path is the proven one).
    private func rcRemoteNSString(_ proc: RemoteCall, _ text: String) -> UInt64 {
        if text.canBeConverted(to: .ascii) {
            return remote_NSString(proc, text)
        }

        let buffer = remote_alloc_str(proc, text)
        guard buffer != 0 else { return 0 }

        let nsStringClass = remote_getClass(proc, "NSString")
        guard nsStringClass != 0 else { return 0 }

        let selWithUTF8 = remote_sel(proc, "stringWithUTF8String:")
        return remote_msg(proc, nsStringClass, selWithUTF8, buffer, 0, 0, 0)
    }

    /// Creates an NSNumber(int) in the remote process. Numeric properties on
    /// the record/domain-data classes are expected to be object-typed, and an
    /// object pointer is also the non-crashing shape if a scalar setter turns
    /// out to read it as a value.
    private func rcRemoteNSNumber(_ proc: RemoteCall, int value: Int) -> UInt64 {
        let cls = remote_getClass(proc, "NSNumber")
        guard cls != 0 else { return 0 }
        let sel = remote_sel(proc, "numberWithInt:")
        guard rcResponds(proc, cls, sel) else { return 0 }
        return remote_msg(proc, cls, sel, UInt64(bitPattern: Int64(value)), 0, 0, 0)
    }

    /// Creates an NSNumber(bool) in the remote process.
    private func rcRemoteNSNumberBool(_ proc: RemoteCall, _ value: Bool) -> UInt64 {
        let cls = remote_getClass(proc, "NSNumber")
        guard cls != 0 else { return 0 }
        let sel = remote_sel(proc, "numberWithBool:")
        guard rcResponds(proc, cls, sel) else { return 0 }
        return remote_msg(proc, cls, sel, value ? 1 : 0, 0, 0, 0)
    }

    /// Reads a NUL-terminated C string out of SpringBoard's address space.
    private func rcReadCString(_ proc: RemoteCall, _ address: UInt64, maxLength: Int = 512) -> String {
        var buffer = [CChar](repeating: 0, count: maxLength)
        let read = buffer.withUnsafeMutableBytes { raw -> Bool in
            proc.remoteRead(address, to: raw.baseAddress, size: UInt64(maxLength - 1))
        }
        guard read else { return "" }
        return String(cString: buffer)
    }

    /// Reads an NSString-returning selector as a Swift String (same pattern as
    /// StatusBarStudioView.readCarrierOverride).
    private func rcStringFromSelector(_ proc: RemoteCall, object: UInt64, _ selectorName: String) -> String {
        guard object != 0 else { return "" }
        let selector = remote_sel(proc, selectorName)
        guard rcResponds(proc, object, selector) else { return "" }

        let nsString = remote_msg(proc, object, selector, 0, 0, 0, 0)
        guard nsString != 0 else { return "" }

        let selUTF8 = remote_sel(proc, "UTF8String")
        let cString = remote_msg(proc, nsString, selUTF8, 0, 0, 0, 0)
        guard cString != 0 else { return "" }

        return rcReadCString(proc, cString)
    }

    /// +[SBSystemStatusStatusBarOverridesArchiver _archiveFileURL] -> NSURL ->
    /// path (absoluteString as fallback). Returns "" when unavailable.
    private func rcArchivePath(_ proc: RemoteCall) -> String {
        let cls = remote_getClass(proc, "SBSystemStatusStatusBarOverridesArchiver")
        guard cls != 0 else { return "" }

        let selURL = remote_sel(proc, "_archiveFileURL")
        guard rcResponds(proc, cls, selURL) else { return "" }

        let url = remote_msg(proc, cls, selURL, 0, 0, 0, 0)
        guard url != 0 else { return "" }

        let path = rcStringFromSelector(proc, object: url, "path")
        if !path.isEmpty { return path }

        let absolute = rcStringFromSelector(proc, object: url, "absoluteString")
        if absolute.hasPrefix("file://"), let decoded = absolute.removingPercentEncoding {
            return String(decoded.dropFirst("file://".count))
        }
        return absolute
    }

    /// Tries the archiver singleton. A fresh instance is never allocated: the
    /// archiver owns observers and a second instance could double-write the
    /// archive file.
    private func rcArchiverInstance(_ proc: RemoteCall) -> UInt64 {
        let cls = remote_getClass(proc, "SBSystemStatusStatusBarOverridesArchiver")
        guard cls != 0 else { return 0 }
        let selShared = remote_sel(proc, "sharedInstance")
        guard rcResponds(proc, cls, selShared) else { return 0 }
        return remote_msg(proc, cls, selShared, 0, 0, 0, 0)
    }

    /// -[SBSystemStatusStatusBarOverridesArchiver _queue_readStatusBarOverridesArchiveRecord]
    /// returns the current record (0 when the archiver is unreachable or the
    /// selector is missing).
    private func rcCurrentArchiveRecord(_ proc: RemoteCall, archiver: UInt64) -> UInt64 {
        guard archiver != 0 else { return 0 }
        let selRead = remote_sel(proc, "_queue_readStatusBarOverridesArchiveRecord")
        guard rcResponds(proc, archiver, selRead) else { return 0 }
        return remote_msg(proc, archiver, selRead, 0, 0, 0, 0)
    }

    /// Allocates a fresh _SBSystemStatusStatusBarOverridesArchiveRecord when no
    /// record could be read. Used as a value carrier for the setters and only
    /// persisted when at least one value actually landed on it.
    private func rcNewArchiveRecord(_ proc: RemoteCall) -> UInt64 {
        let cls = remote_getClass(proc, "_SBSystemStatusStatusBarOverridesArchiveRecord")
        guard cls != 0 else { return 0 }
        let selNew = remote_sel(proc, "new")
        guard rcResponds(proc, cls, selNew) else { return 0 }
        return remote_msg(proc, cls, selNew, 0, 0, 0, 0)
    }

    /// [STMutableStatusBarOverridesStatusDomainData new]
    private func rcNewDomainData(_ proc: RemoteCall) -> UInt64 {
        let cls = remote_getClass(proc, "STMutableStatusBarOverridesStatusDomainData")
        guard cls != 0 else { return 0 }
        let selNew = remote_sel(proc, "new")
        guard rcResponds(proc, cls, selNew) else { return 0 }
        return remote_msg(proc, cls, selNew, 0, 0, 0, 0)
    }

    /// [STStatusBarOverridesStatusDomainPublisher new]
    private func rcNewPublisher(_ proc: RemoteCall) -> UInt64 {
        let cls = remote_getClass(proc, "STStatusBarOverridesStatusDomainPublisher")
        guard cls != 0 else { return 0 }
        let selNew = remote_sel(proc, "new")
        guard rcResponds(proc, cls, selNew) else { return 0 }
        return remote_msg(proc, cls, selNew, 0, 0, 0, 0)
    }

    /// [UIApplication sharedApplication].delegate - inside SpringBoard this is
    /// the SpringBoard app-delegate object that carries the _sbApply... method.
    private func rcSpringBoardObject(_ proc: RemoteCall) -> UInt64 {
        let uiAppClass = remote_getClass(proc, "UIApplication")
        guard uiAppClass != 0 else { return 0 }

        let selSharedApplication = remote_sel(proc, "sharedApplication")
        let app = remote_msg(proc, uiAppClass, selSharedApplication, 0, 0, 0, 0)
        guard app != 0 else { return 0 }

        let selDelegate = remote_sel(proc, "delegate")
        guard rcResponds(proc, app, selDelegate) else { return 0 }
        return remote_msg(proc, app, selDelegate, 0, 0, 0, 0)
    }

    private func rcRecordClassInfo(_ proc: RemoteCall) -> String {
        let cls = remote_getClass(proc, "_SBSystemStatusStatusBarOverridesArchiveRecord")
        guard cls != 0 else { return "record class missing" }

        let selSecure = remote_sel(proc, "supportsSecureCoding")
        if rcResponds(proc, cls, selSecure) {
            let secure = remote_msg(proc, cls, selSecure, 0, 0, 0, 0) != 0
            return "record class ok (supportsSecureCoding=\(secure ? "yes" : "no"))"
        }
        return "record class ok (supportsSecureCoding unknown)"
    }

    // MARK: - Target resolution and gated calls

    private struct rcTargets {
        var aggregator: UInt64 = 0
        var archiver: UInt64 = 0
        var record: UInt64 = 0          // record read from the archiver, if any
        var recordTarget: UInt64 = 0    // record, or a fresh one as carrier
        var domainData: UInt64 = 0
        var springboard: UInt64 = 0

        /// Setter targets, in priority order: the persisted record first, then
        /// the archiver, the live aggregator and finally the domain data.
        var list: [(name: String, object: UInt64)] {
            var out: [(name: String, object: UInt64)] = []
            if recordTarget != 0 { out.append((name: "archiveRecord", object: recordTarget)) }
            if archiver != 0 { out.append((name: "archiver", object: archiver)) }
            if aggregator != 0 { out.append((name: "aggregator", object: aggregator)) }
            if domainData != 0 { out.append((name: "domainData", object: domainData)) }
            return out
        }
    }

    private func resolveTargets(_ proc: RemoteCall) -> rcTargets {
        var targets = rcTargets()
        targets.aggregator = rcStatusBarAggregator(proc)
        targets.archiver = rcArchiverInstance(proc)
        targets.record = rcCurrentArchiveRecord(proc, archiver: targets.archiver)
        targets.recordTarget = targets.record != 0 ? targets.record : rcNewArchiveRecord(proc)
        targets.domainData = rcNewDomainData(proc)
        targets.springboard = rcSpringBoardObject(proc)
        return targets
    }

    private struct rcApplyHit {
        let target: String
        let selector: String
    }

    /// Sends the first selector the first target implements, with one argument.
    /// Never sends an unrecognized selector.
    private func rcSetValue(_ proc: RemoteCall,
                            targets: [(name: String, object: UInt64)],
                            selectorNames: [String],
                            value: UInt64,
                            label: String,
                            applied: inout [String],
                            missing: inout [String]) -> rcApplyHit? {
        for target in targets where target.object != 0 {
            for selectorName in selectorNames {
                let selector = remote_sel(proc, selectorName)
                if rcResponds(proc, target.object, selector) {
                    remote_msg(proc, target.object, selector, value, 0, 0, 0)
                    applied.append("\(label) via \(target.name) -\(selectorName)")
                    return rcApplyHit(target: target.name, selector: selectorName)
                }
            }
        }
        missing.append("\(label) (\(selectorNames.joined(separator: ", ")))")
        return nil
    }

    /// Sends a one-argument selector when the target implements it.
    @discardableResult
    private func rcCallIfResponds(_ proc: RemoteCall, _ object: UInt64, _ selectorName: String, _ argument: UInt64) -> Bool {
        guard object != 0 else { return false }
        let selector = remote_sel(proc, selectorName)
        guard rcResponds(proc, object, selector) else { return false }
        remote_msg(proc, object, selector, argument, 0, 0, 0)
        return true
    }

    // MARK: - Actions

    /// Persistence step shared by Apply and Clear: persist/write-out the record,
    /// nudge the archiver, ask SpringBoard to apply the record and publish the
    /// domain data. Returns the calls that actually ran.
    private func persistFakes(_ proc: RemoteCall, targets: rcTargets, recordValuesSet: Bool) -> [String] {
        var persist: [String] = []

        if targets.archiver != 0, targets.recordTarget != 0, targets.record != 0 || recordValuesSet {
            if rcCallIfResponds(proc, targets.archiver, "_queue_persistUpdatedArchiveRecord:", targets.recordTarget) {
                persist.append("persist")
            }
            if rcCallIfResponds(proc, targets.archiver, "_queue_writeOutArchiveRecord:", targets.recordTarget) {
                persist.append("writeOut")
            }
        }
        if targets.archiver != 0 {
            if rcCallIfResponds(proc, targets.archiver, "_queue_setupObservingAndReconcileInitialState", 0) {
                persist.append("reconcile")
            }
        }
        if targets.springboard != 0, targets.recordTarget != 0 {
            if rcCallIfResponds(proc, targets.springboard, "_sbApplySystemStatusStatusBarOverridesArchiveRecord:", targets.recordTarget) {
                persist.append("sbApply")
            }
        }
        if targets.domainData != 0 {
            let publisher = rcNewPublisher(proc)
            if publisher != 0, rcCallIfResponds(proc, publisher, "updateData:", targets.domainData) {
                persist.append("publish")
            }
        }
        return persist
    }

    private func applyFakes(_ settings: fakeSettings) -> String {
        guard mgr.rcready, let proc = mgr.sbProc else {
            return "apply -> failed (RemoteCall not initialized)"
        }

        var applied: [String] = []
        var missing: [String] = []
        var notes: [String] = []

        let path = rcArchivePath(proc)
        if path.isEmpty {
            notes.append("archive path not discovered")
        } else {
            DispatchQueue.main.async { self.archivePath = path }
            notes.append("archive=\(path)")

            // Safety copy before the persist calls below let SpringBoard write
            // the archive (requirement: back up before any write).
            var fileExists = FileManager.default.fileExists(atPath: path)
            if !fileExists, mgr.vfsready {
                fileExists = mgr.vfssize(path: path) >= 0
            }
            if fileExists {
                let backup = backupArchive(path: path)
                notes.append(backup)
                if !backup.hasPrefix("backup -> ok") {
                    return "apply -> failed (could not back up the archive before writing; \(backup))"
                }
            } else {
                notes.append("no archive file yet (nothing to back up)")
            }
        }

        let targets = resolveTargets(proc)
        if targets.list.isEmpty {
            return "apply -> failed (no candidate targets reachable)"
        }

        var recordValuesSet = false

        if settings.batteryEnabled {
            let percentage = rcRemoteNSNumber(proc, int: settings.batteryPercentage)
            if percentage != 0 {
                let hit = rcSetValue(proc, targets: targets.list, selectorNames: ["setBatteryPercentage:"],
                                     value: percentage, label: "batteryPercentage=\(settings.batteryPercentage)",
                                     applied: &applied, missing: &missing)
                if hit?.target == "archiveRecord" { recordValuesSet = true }
            } else {
                missing.append("batteryPercentage (remote NSNumber failed)")
            }

            let charging = rcRemoteNSNumberBool(proc, settings.batteryCharging)
            if charging != 0 {
                let hit = rcSetValue(proc, targets: targets.list,
                                     selectorNames: ["setBatteryCharging:", "setCharging:", "setBatteryIsCharging:", "setIsCharging:"],
                                     value: charging, label: "charging=\(settings.batteryCharging)",
                                     applied: &applied, missing: &missing)
                if hit?.target == "archiveRecord" { recordValuesSet = true }
            } else {
                missing.append("charging (remote NSNumber failed)")
            }
        }

        let wifi = rcRemoteNSNumber(proc, int: settings.wifiBars)
        if wifi != 0 {
            let hit = rcSetValue(proc, targets: targets.list, selectorNames: ["setWifiBars:", "setWiFiBars:"],
                                 value: wifi, label: "wifiBars=\(settings.wifiBars)",
                                 applied: &applied, missing: &missing)
            if hit?.target == "archiveRecord" { recordValuesSet = true }
        } else {
            missing.append("wifiBars (remote NSNumber failed)")
        }

        let cellular = rcRemoteNSNumber(proc, int: settings.cellularBars)
        if cellular != 0 {
            let hit = rcSetValue(proc, targets: targets.list, selectorNames: ["setCellularBars:"],
                                 value: cellular, label: "cellularBars=\(settings.cellularBars)",
                                 applied: &applied, missing: &missing)
            if hit?.target == "archiveRecord" { recordValuesSet = true }
        } else {
            missing.append("cellularBars (remote NSNumber failed)")
        }

        if !settings.carrierText.isEmpty {
            let carrier = rcRemoteNSString(proc, settings.carrierText)
            if carrier != 0 {
                let hit = rcSetValue(proc, targets: targets.list, selectorNames: ["setCarrierName:"],
                                     value: carrier, label: "carrier=\"\(settings.carrierText)\"",
                                     applied: &applied, missing: &missing)
                if hit?.target == "archiveRecord" { recordValuesSet = true }
            } else {
                missing.append("carrierName (remote NSString failed)")
            }
        }

        if !settings.overrideTimeText.isEmpty {
            let time = rcRemoteNSString(proc, settings.overrideTimeText)
            if time != 0 {
                let hit = rcSetValue(proc, targets: targets.list, selectorNames: ["setOverrideTime:"],
                                     value: time, label: "overrideTime=\"\(settings.overrideTimeText)\"",
                                     applied: &applied, missing: &missing)
                if hit?.target == "archiveRecord" { recordValuesSet = true }
            } else {
                missing.append("overrideTime (remote NSString failed)")
            }
        }

        let persist = persistFakes(proc, targets: targets, recordValuesSet: recordValuesSet)
        let refresh = rcDispatchUpdates(proc, aggregator: targets.aggregator,
                                        selectors: ["_updateBatteryItems", "_updateOverrideDate", "_updateTimeItems",
                                                    "_updatePersonNameItem", "_updateDataNetworkItem"])

        var result = "apply -> set: " + (applied.isEmpty ? "nothing" : applied.joined(separator: ", "))
        if !missing.isEmpty {
            result += " | missing: " + missing.joined(separator: ", ")
        }
        result += " | persist: " + (persist.isEmpty ? "none" : persist.joined(separator: ", "))
        result += " | refresh: " + (refresh.performed.isEmpty ? "none" : refresh.performed.joined(separator: ", "))
        if !refresh.missing.isEmpty {
            result += " (refresh missing: \(refresh.missing.joined(separator: ", ")))"
        }
        result += " | " + notes.joined(separator: ", ")
        return result
    }

    private func clearFakes() -> String {
        guard mgr.rcready, let proc = mgr.sbProc else {
            return "clear -> failed (RemoteCall not initialized)"
        }

        var applied: [String] = []
        var missing: [String] = []

        let path = rcArchivePath(proc)
        if !path.isEmpty {
            DispatchQueue.main.async { self.archivePath = path }
        }

        // Safety copy before the persist calls below let SpringBoard write the
        // archive (requirement: back up before any write).
        var backupNote = ""
        if !path.isEmpty {
            var fileExists = FileManager.default.fileExists(atPath: path)
            if !fileExists, mgr.vfsready {
                fileExists = mgr.vfssize(path: path) >= 0
            }
            if fileExists {
                let backup = backupArchive(path: path)
                if !backup.hasPrefix("backup -> ok") {
                    return "clear -> failed (could not back up the archive before writing; \(backup))"
                }
                backupNote = " | " + backup
            }
        }

        let targets = resolveTargets(proc)
        if targets.list.isEmpty {
            return "clear -> failed (no candidate targets reachable)"
        }

        var recordValuesSet = false

        if rcSetValue(proc, targets: targets.list, selectorNames: ["setBatteryPercentage:"],
                      value: 0, label: "batteryPercentage=nil",
                      applied: &applied, missing: &missing)?.target == "archiveRecord" {
            recordValuesSet = true
        }

        if rcSetValue(proc, targets: targets.list,
                      selectorNames: ["setBatteryCharging:", "setCharging:", "setBatteryIsCharging:", "setIsCharging:"],
                      value: 0, label: "charging=nil",
                      applied: &applied, missing: &missing)?.target == "archiveRecord" {
            recordValuesSet = true
        }

        if rcSetValue(proc, targets: targets.list, selectorNames: ["setWifiBars:", "setWiFiBars:"],
                      value: 0, label: "wifiBars=0",
                      applied: &applied, missing: &missing)?.target == "archiveRecord" {
            recordValuesSet = true
        }

        if rcSetValue(proc, targets: targets.list, selectorNames: ["setCellularBars:"],
                      value: 0, label: "cellularBars=0",
                      applied: &applied, missing: &missing)?.target == "archiveRecord" {
            recordValuesSet = true
        }

        let empty = rcRemoteNSString(proc, "")
        if empty != 0 {
            if rcSetValue(proc, targets: targets.list, selectorNames: ["setCarrierName:"],
                          value: empty, label: "carrier=\"\"",
                          applied: &applied, missing: &missing)?.target == "archiveRecord" {
                recordValuesSet = true
            }
        }

        if rcSetValue(proc, targets: targets.list, selectorNames: ["setOverrideTime:"],
                      value: 0, label: "overrideTime=nil",
                      applied: &applied, missing: &missing)?.target == "archiveRecord" {
            recordValuesSet = true
        }

        let persist = persistFakes(proc, targets: targets, recordValuesSet: recordValuesSet)
        let refresh = rcDispatchUpdates(proc, aggregator: targets.aggregator,
                                        selectors: ["_updateBatteryItems", "_updateOverrideDate", "_updateTimeItems",
                                                    "_updatePersonNameItem", "_updateDataNetworkItem"])

        var result = "clear -> " + (applied.isEmpty ? "nothing" : applied.joined(separator: ", "))
        if !missing.isEmpty {
            result += " | missing: " + missing.joined(separator: ", ")
        }
        result += " | persist: " + (persist.isEmpty ? "none" : persist.joined(separator: ", "))
        result += " | refresh: " + (refresh.performed.isEmpty ? "none" : refresh.performed.joined(separator: ", "))
        result += backupNote
        return result
    }

    private func discoverArchive() -> String {
        guard mgr.rcready, let proc = mgr.sbProc else {
            return "discover -> failed (RemoteCall not initialized)"
        }

        let path = rcArchivePath(proc)
        guard !path.isEmpty else {
            return "discover -> failed (_archiveFileURL unavailable: archiver class missing or selector not implemented)"
        }

        DispatchQueue.main.async { self.archivePath = path }

        var exists = FileManager.default.fileExists(atPath: path)
        if !exists, mgr.vfsready {
            exists = mgr.vfssize(path: path) >= 0
        }

        let archiver = rcArchiverInstance(proc) != 0 ? "archiver instance yes" : "archiver instance no"
        let recordInfo = rcRecordClassInfo(proc)
        return "discover -> \(path) (file \(exists ? "exists" : "not present yet"), \(archiver), \(recordInfo))"
    }

    private func backupArchive(path: String) -> String {
        guard !path.isEmpty else {
            return "backup -> failed (discover the archive path first)"
        }

        guard let data = mgspoofreaddata(path: path, maxSize: 4 * 1024 * 1024) else {
            return "backup -> failed (could not read \(path); sbx/vfs not ready?)"
        }

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lara_backups", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "statusbaroverrides-\(formatter.string(from: Date())).archive"
            let dest = dir.appendingPathComponent(name)
            try data.write(to: dest, options: .atomic)
            DispatchQueue.main.async { self.backupPath = dest.path }
            return "backup -> ok (\(name), \(data.count) bytes)"
        } catch {
            return "backup -> failed (\(error.localizedDescription))"
        }
    }

    private func restoreArchive(path: String, backup: String) -> String {
        guard !path.isEmpty else {
            return "restore -> failed (discover the archive path first)"
        }
        guard !backup.isEmpty, FileManager.default.fileExists(atPath: backup) else {
            return "restore -> failed (no session backup taken yet)"
        }

        // snapshot the current archive before overwriting it, so a wrong restore is recoverable
        let prebackup = backupArchive(path: path)
        if !prebackup.hasPrefix("backup -> ok") {
            return "restore -> failed (could not back up current archive: \(prebackup))"
        }

        let result = mgr.lara_overwritefile(target: path, source: backup, fallback_vfs: false)
        if result.ok {
            return "restore -> ok (\(backup) -> \(path))"
        }
        return "restore -> failed (\(result.message))"
    }

    private func removeArchive(path: String) -> String {
        guard !path.isEmpty else {
            return "remove -> failed (discover the archive path first)"
        }

        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path)

        // Never delete or truncate without a copy of what is being removed.
        if exists {
            let backup = backupArchive(path: path)
            if !backup.hasPrefix("backup -> ok") {
                return "remove -> failed (could not back up the archive before removing it; \(backup))"
            }
        }

        do {
            if exists {
                try fm.removeItem(atPath: path)
                return "remove -> deleted \(path)"
            }
            return "remove -> no file at \(path)"
        } catch {
            // Fallback: truncate through the sbx write path. SpringBoard treats
            // an empty/invalid record as a reset and evicts the file itself.
            let result = mgr.lara_overwritefile(target: path, data: Data(), fallback_vfs: false)
            if result.ok {
                return "remove -> deletion failed (\(error.localizedDescription)); truncated to 0 bytes instead"
            }
            return "remove -> failed (\(error.localizedDescription); truncate also failed: \(result.message))"
        }
    }

    // MARK: - Version spoof loading

    private func loadVersionValues() {
        DispatchQueue.global(qos: .userInitiated).async {
            let values = mgspoofreadvalues()
            let real = mgspoofrealvalues()
            DispatchQueue.main.async {
                self.mgValues = values.values
                self.mgUnmapped = values.unmapped
                self.mgReadMessage = values.message
                self.mgRealValues = real
            }
        }
    }
}
