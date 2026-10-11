//
//  StatusBarStudioView.swift
//  lara
//
//  Status Bar Override Studio.
//
//  Drives SpringBoard's SBStatusBarStateAggregator through the existing RemoteCall
//  primitive (mgr.sbProc). The remote calls mirror the proven pattern in
//  lara/kexploit/pe/rc.m: status_bar_time_format() (~line 44):
//      UIApplication.sharedApplication -> statusBarStateAggregator
//      remote_NSString() for string arguments
//      performSelectorOnMainThread:withObject:waitUntilDone: for _update* selectors
//
//  The C helpers used here (remote_sel / remote_msg / remote_getClass /
//  remote_NSString / remote_alloc_str / RemoteCall.remoteRead) come from
//  RemoteCall.h, which is imported by lara-Bridging-Header.h, so they are visible
//  to Swift without touching laramgr or rc.m.
//
//  See docs/dev/statusbar-integration.md for the selector inventory, verification
//  status and risk notes.
//

import SwiftUI

struct StatusBarStudioView: View {
    @ObservedObject var mgr: laramgr

    @State private var carrierText: String = ""
    @State private var running: Bool = false
    @State private var lastAction: String = ""
    @State private var lastResult: String = ""

    var body: some View {
        List {
            statusSection
            carrierSection
            itemsSection
            clockSection
            lastResultSection
        }
        .navigationTitle(Text("Status Bar Studio"))
    }

    // MARK: - Status

    private var statusSection: some View {
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
                if mgr.sbProc != nil {
                    Text("bound")
                        .foregroundColor(.secondary)
                } else {
                    Text("missing")
                        .foregroundColor(.secondary)
                }
            }

            if let error = mgr.sbProc?.lastError, !error.isEmpty {
                Text("Last RemoteCall error: \(error)")
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            Button {
                run("Read Carrier Override") {
                    readCarrierOverride()
                }
            } label: {
                Text("Read current override")
            }
            .disabled(!mgr.rcready || running)
        } header: {
            Text("Status")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !mgr.rcready {
                    Text("RemoteCall is not initialized. How are you here?")
                    Text("Run the exploit first, then tap Initialize RemoteCall on the main screen (RemoteCall section) to bind to SpringBoard before using this studio.")
                }
                Text("RemoteCall is relatively unstable and may not work properly.")
            }
        }
    }

    // MARK: - Carrier / operator text

    private var carrierSection: some View {
        Section {
            TextField("Operator text (e.g. lara)", text: $carrierText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: carrierText) { newValue in
                    if newValue.count > 64 {
                        carrierText = String(newValue.prefix(64))
                    }
                }

            Button {
                run("Apply Carrier Override") {
                    let text = carrierText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        return "carrier override apply -> failed (text is empty, use Clear instead)"
                    }
                    return setCarrierOverride(text, label: "apply")
                }
            } label: {
                Text("Apply")
            }

            Button {
                run("Clear Carrier Override") {
                    setCarrierOverride("", label: "clear")
                }
            } label: {
                Text("Clear (empty string)")
            }
        } header: {
            Text("Carrier / Operator Text")
        } footer: {
            Text("Calls setUserNameOverride: followed by _updatePersonNameItem / _updateDataNetworkItem on SBStatusBarStateAggregator in SpringBoard. The override is live only: it is lost after a respring or any SpringBoard restart.")
        }
        .disabled(!mgr.rcready || running)
    }

    // MARK: - Status items

    private var itemsSection: some View {
        Section {
            Button {
                run("Repair Status Bar") {
                    repairStatusBar()
                }
            } label: {
                Text("Repair status bar")
            }

            Button {
                run("Refresh Battery Items") {
                    refreshBatteryItems()
                }
            } label: {
                Text("Refresh battery items (experimental)")
            }
        } header: {
            Text("Status Items")
        } footer: {
            Text("Repair re-dispatches every known update selector that the aggregator responds to (_updatePersonNameItem, _updateDataNetworkItem, _updateBatteryItems, _updateOverrideDate, _updateTimeItems). Battery refresh only calls _updateBatteryItems: no verified override-battery setter exists on iOS 26, so fake values are not exposed yet.")
        }
        .disabled(!mgr.rcready || running)
    }

    // MARK: - Time

    private var clockSection: some View {
        Section {
            Button {
                run("Refresh Override Date") {
                    refreshOverrideDate()
                }
            } label: {
                Text("Refresh clock (_updateOverrideDate)")
            }
        } header: {
            Text("Time Override")
        } footer: {
            Text("Refresh only: _updateOverrideDate is dispatched with no arguments. Setting a specific override date needs a verified setter that takes an NSDate (see the TODO in the source and docs/dev/statusbar-integration.md), so it is intentionally not exposed.")
        }
        .disabled(!mgr.rcready || running)
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
            Text("Overrides live in SpringBoard memory only and do not survive a respring. Keep RemoteCall initialized while using this screen.")
        }
    }

    // MARK: - Actions

    /// Couple of lines of log, same shape as rc.m's printf diagnostics.
    private func setCarrierOverride(_ text: String, label: String) -> String {
        guard mgr.rcready, let proc = mgr.sbProc else {
            return "carrier override \(label) -> failed (RemoteCall not initialized)"
        }

        let aggregator = rcStatusBarAggregator(proc)
        guard aggregator != 0 else {
            return "carrier override \(label) -> failed (SBStatusBarStateAggregator not reachable)"
        }

        let selSetUserName = remote_sel(proc, "setUserNameOverride:")
        guard rcResponds(proc, aggregator, selSetUserName) else {
            return "carrier override \(label) -> failed (setUserNameOverride: not available on this build)"
        }

        let value = rcRemoteNSString(proc, text)
        guard value != 0 else {
            return "carrier override \(label) -> failed (remote NSString allocation failed)"
        }

        remote_msg(proc, aggregator, selSetUserName, value, 0, 0, 0)

        let updates = rcDispatchUpdates(proc, aggregator: aggregator,
                                        selectors: ["_updatePersonNameItem", "_updateDataNetworkItem"])
        var result = "carrier override \(label) \"\(text)\" -> ok (\(updates.performed.count) refresh(es))"
        if !updates.missing.isEmpty {
            result += " (missing: \(updates.missing.joined(separator: ", ")))"
        }
        return result
    }

    /// Re-runs every update selector the running iOS build actually implements.
    private func repairStatusBar() -> String {
        guard mgr.rcready, let proc = mgr.sbProc else {
            return "repair -> failed (RemoteCall not initialized)"
        }

        let aggregator = rcStatusBarAggregator(proc)
        guard aggregator != 0 else {
            return "repair -> failed (SBStatusBarStateAggregator not reachable)"
        }

        let updates = rcDispatchUpdates(proc, aggregator: aggregator,
                                        selectors: ["_updatePersonNameItem", "_updateDataNetworkItem",
                                                    "_updateBatteryItems", "_updateOverrideDate",
                                                    "_updateTimeItems"])
        var result = "repair -> ok (\(updates.performed.joined(separator: ", ")))"
        if !updates.missing.isEmpty {
            result += " (missing: \(updates.missing.joined(separator: ", ")))"
        }
        return result
    }

    /// Refresh-only: no verified battery override setter exists, so this just asks
    /// the aggregator to rebuild its battery items (experimental).
    private func refreshBatteryItems() -> String {
        guard mgr.rcready, let proc = mgr.sbProc else {
            return "battery refresh -> failed (RemoteCall not initialized)"
        }

        let aggregator = rcStatusBarAggregator(proc)
        guard aggregator != 0 else {
            return "battery refresh -> failed (SBStatusBarStateAggregator not reachable)"
        }

        let selector = remote_sel(proc, "_updateBatteryItems")
        guard rcResponds(proc, aggregator, selector) else {
            return "battery refresh -> failed (_updateBatteryItems not available on this build)"
        }

        rcDispatch(proc, target: aggregator, selector: selector)
        return "battery refresh -> ok (experimental, refresh only)"
    }

    /// _updateOverrideDate is a zero-argument refresh selector. TODO: the actual
    /// date override needs a verified setter on iOS 26 (candidate:
    /// -[SBStatusBarStateAggregator setOverrideDate:] taking an NSDate created
    /// remotely). Its signature is not confirmed yet, so do not call it here.
    private func refreshOverrideDate() -> String {
        guard mgr.rcready, let proc = mgr.sbProc else {
            return "clock refresh -> failed (RemoteCall not initialized)"
        }

        let aggregator = rcStatusBarAggregator(proc)
        guard aggregator != 0 else {
            return "clock refresh -> failed (SBStatusBarStateAggregator not reachable)"
        }

        let selector = remote_sel(proc, "_updateOverrideDate")
        guard rcResponds(proc, aggregator, selector) else {
            return "clock refresh -> failed (_updateOverrideDate not available on this build)"
        }

        rcDispatch(proc, target: aggregator, selector: selector)
        return "clock refresh -> ok (_updateOverrideDate dispatched)"
    }

    /// Reads back statusBarUserNameOverride and converts it to a local String.
    private func readCarrierOverride() -> String {
        guard mgr.rcready, let proc = mgr.sbProc else {
            return "read override -> failed (RemoteCall not initialized)"
        }

        let aggregator = rcStatusBarAggregator(proc)
        guard aggregator != 0 else {
            return "read override -> failed (SBStatusBarStateAggregator not reachable)"
        }

        let selGetter = remote_sel(proc, "statusBarUserNameOverride")
        guard rcResponds(proc, aggregator, selGetter) else {
            return "read override -> failed (statusBarUserNameOverride not available on this build)"
        }

        let nsString = remote_msg(proc, aggregator, selGetter, 0, 0, 0, 0)
        guard nsString != 0 else {
            return "read override -> (no override set)"
        }

        let selUTF8 = remote_sel(proc, "UTF8String")
        let cString = remote_msg(proc, nsString, selUTF8, 0, 0, 0, 0)
        guard cString != 0 else {
            return "read override -> failed (UTF8String returned NULL)"
        }

        return "read override -> \"\(rcReadCString(proc, cString))\""
    }

    // MARK: - RemoteCall bridge
    //
    // These helpers are the Swift translation of rc.m's status_bar_time_format().
    // Everything is executed inside SpringBoard by RemoteCall: the objc_msgSend /
    // sel_registerName function pointers used internally live in the dyld shared
    // cache, which is mapped at the same address in every process.

    /// [[UIApplication sharedApplication] statusBarStateAggregator], same lookup
    /// rc.m's status_bar_time_format() uses (proven pattern, iOS 16 - 26).
    private func rcStatusBarAggregator(_ proc: RemoteCall) -> UInt64 {
        let uiAppClass = remote_getClass(proc, "UIApplication")
        guard uiAppClass != 0 else { return 0 }

        let selSharedApplication = remote_sel(proc, "sharedApplication")
        let app = remote_msg(proc, uiAppClass, selSharedApplication, 0, 0, 0, 0)
        guard app != 0 else { return 0 }

        let selAggregator = remote_sel(proc, "statusBarStateAggregator")
        return remote_msg(proc, app, selAggregator, 0, 0, 0, 0)
    }

    /// Ask the remote object itself before sending a private selector: an
    /// unrecognized selector would raise inside SpringBoard and take it down.
    private func rcResponds(_ proc: RemoteCall, _ object: UInt64, _ selector: UInt64) -> Bool {
        guard object != 0, selector != 0 else { return false }
        let selResponds = remote_sel(proc, "respondsToSelector:")
        return remote_msg(proc, object, selResponds, selector, 0, 0, 0) != 0
    }

    /// Queues a zero-argument selector on SpringBoard's main thread.
    /// Mirrors rc.m: performSelectorOnMainThread:withObject:waitUntilDone: with a
    /// nil object and waitUntilDone = NO. Never blocks the RemoteCall thread.
    private func rcDispatch(_ proc: RemoteCall, target: UInt64, selector: UInt64) {
        let selPerform = remote_sel(proc, "performSelectorOnMainThread:withObject:waitUntilDone:")
        remote_msg(proc, target, selPerform, selector, 0, 0, 0)
    }

    /// Dispatches every selector the aggregator responds to and reports which
    /// ones were missing, so the UI can say what the running iOS build supports.
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

    /// Creates an NSString in the remote process.
    /// remote_NSString() (proven in rc.m) goes through stringWithCString:, so the
    /// plain ASCII path stays exactly the proven one. For anything outside ASCII
    /// fall back to stringWithUTF8String: with a remote malloc; that C buffer is
    /// intentionally leaked because no remote free() helper is exposed to Swift
    /// (a few bytes per Apply, acceptable for this tool).
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

    /// Reads a NUL-terminated C string out of SpringBoard's address space.
    private func rcReadCString(_ proc: RemoteCall, _ address: UInt64, maxLength: Int = 256) -> String {
        var buffer = [CChar](repeating: 0, count: maxLength)
        let read = buffer.withUnsafeMutableBytes { raw -> Bool in
            proc.remoteRead(address, to: raw.baseAddress, size: UInt64(maxLength - 1))
        }
        guard read else { return "" }
        return String(cString: buffer)
    }

    // MARK: - Run helper (shape copied from RemoteView)

    private func run(_ name: String, _ work: @escaping () -> String) {
        guard mgr.rcready, !running else { return }
        running = true
        mgr.logmsg("(rc) \(name)...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.mgr.logmsg("(rc) \(result)")
                self.lastAction = name
                self.lastResult = result
                if self.isRemoteCallFailure(result) {
                    Alertinator.shared.alert(title: "\(name) Failed", body: result)
                }
                self.running = false
            }
        }
    }

    private func isRemoteCallFailure(_ result: String) -> Bool {
        let lowercased = result.lowercased()
        return lowercased.contains("-> -1") ||
            lowercased.contains("-> failed") ||
            lowercased.contains(": failed") ||
            lowercased.contains("failed to")
    }
}
