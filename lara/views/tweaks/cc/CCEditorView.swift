//
//  CCEditorView.swift
//  lara
//
//  Control Center Layout Editor.
//
//  This replaces the old, non-functional dirtyZero "Control Center" section
//  with a real editor for the Control Center module configuration.
//
//  ON-DEVICE RESEARCH STATUS (iOS 26.0):
//  The exact on-disk location and schema of the Control Center module layout is
//  NOT confirmed. The locations probed below are educated guesses:
//    a) /var/mobile/Library/Preferences/com.apple.ControlCenter.plist
//    b) /var/mobile/Library/Preferences/com.apple.ControlCenterSettings.plist
//    c) a ModuleConfiguration.plist inside the ControlCenter app container
//       (containers are discovered through laramgr.getAppList()).
//  Because the schema may be nested and the path is unknown, this view probes
//  EVERY candidate on every refresh, logs each probe/read/write through
//  globallogger, and shows the results in the UI so they can be reported back.
//  The editor adapts to whichever file and key nesting actually exists.
//
//  Keys managed (in whichever plist/casing is found):
//    - orderedUserEnabledModuleIdentifiers (array of strings)
//    - userDisabledModuleIdentifiers       (array of strings)
//  If a key is nested, it is updated in place; otherwise it is created at the
//  top level of the selected plist. All of this is deliberately probe-and-log
//  until an on-device test confirms the real layout.
//
//  Writes are backed up to Documents/lara_backups/cceditor/ first:
//    - orig-<sanitized-path>                   (first-seen original, kept)
//    - snapshot-<timestamp>-<sanitized-path>   (taken before every write)
//  "Reset to Defaults" restores the original backup when one exists and
//  otherwise removes the two managed keys.
//
//  Applying/resetting ends with the same respring mechanism as the other tweak
//  views (Alertinator + mgr.respring()).

import SwiftUI

// MARK: - constants

private let cceditorEnabledKey = "orderedUserEnabledModuleIdentifiers"
private let cceditorDisabledKey = "userDisabledModuleIdentifiers"
private let cceditorStandardPath = "/var/mobile/Library/Preferences/com.apple.ControlCenter.plist"

private struct CCEditorModule: Identifiable, Hashable {
    let identifier: String
    let name: String
    let detail: String

    var id: String { identifier }
}

// The first six entries are verified iOS 26.0 module identifiers. The
// accessibility entries are offered with and without the
// "com.apple.control-center." prefix because the exact form is unconfirmed;
// custom identifiers can always be typed in by hand.
private let cceditorModuleCatalog: [CCEditorModule] = [
    CCEditorModule(identifier: "com.apple.control-center.MuteModule", name: "Mute", detail: "Verified identifier"),
    CCEditorModule(identifier: "com.apple.control-center.FlashlightModule", name: "Flashlight", detail: "Verified identifier"),
    CCEditorModule(identifier: "com.apple.control-center.QrCodeModule", name: "QR Code", detail: "Verified identifier"),
    CCEditorModule(identifier: "com.apple.control-center.OrientationLockModule", name: "Orientation Lock", detail: "Verified identifier"),
    CCEditorModule(identifier: "com.apple.control-center.LowPowerModule", name: "Low Power Mode", detail: "Verified identifier"),
    CCEditorModule(identifier: "com.apple.control-center.ScreenMirroring", name: "Screen Mirroring", detail: "Verified identifier"),
    CCEditorModule(identifier: "com.apple.control-center.HearingAidsModule", name: "Hearing Aids", detail: "Accessibility, prefixed variant"),
    CCEditorModule(identifier: "HearingAidsModule", name: "Hearing Aids (short)", detail: "Accessibility, unprefixed variant"),
    CCEditorModule(identifier: "com.apple.control-center.MagnifierModule", name: "Magnifier", detail: "Accessibility, prefixed variant"),
    CCEditorModule(identifier: "MagnifierModule", name: "Magnifier (short)", detail: "Accessibility, unprefixed variant"),
    CCEditorModule(identifier: "com.apple.control-center.ShazamModule", name: "Shazam", detail: "Accessibility, prefixed variant"),
    CCEditorModule(identifier: "ShazamModule", name: "Shazam (short)", detail: "Accessibility, unprefixed variant"),
    CCEditorModule(identifier: "com.apple.control-center.AccessibilityMotionCuesControlCenterModule", name: "Motion Cues", detail: "Accessibility, prefixed variant"),
    CCEditorModule(identifier: "AccessibilityMotionCuesControlCenterModule", name: "Motion Cues (short)", detail: "Accessibility, unprefixed variant"),
]

// A single probed candidate location plus whatever we were able to learn
// about it. Everything in here is shown in the UI and logged.
private struct CCEditorSource: Identifiable {
    let path: String
    let label: String
    var exists: Bool
    var readable: Bool
    var topLevelKeys: [String]
    var enabledKeyLocation: String?
    var disabledKeyLocation: String?
    var enabledCount: Int?
    var error: String?

    var id: String { path }
}

// MARK: - view

struct CCEditorView: View {
    @ObservedObject var mgr: laramgr

    @State private var sources: [CCEditorSource] = []
    @State private var activePath: String?
    @State private var enabledModules: [String] = []
    @State private var disabledModules: [String] = []
    @State private var customIdentifier: String = ""
    @State private var isLoading: Bool = false
    @State private var status: String = ""
    @State private var showResetConfirm: Bool = false

    private var canEdit: Bool { mgr.sbxready && activePath != nil }
    private var canProbe: Bool { mgr.sbxready }

    var body: some View {
        List {
            if !mgr.sbxready {
                Section {
                    Text("Sandbox escape is not ready. Run the exploit and initialize the sandbox escape first.")
                        .foregroundColor(.secondary)
                } header: {
                    HeaderLabel(text: "Not Ready", icon: "exclamationmark.triangle")
                }
            }

            if canProbe {
                probeSection
                editorSection
                addSection
                catalogSection
                disabledSection
                actionsSection
            }

            if !status.isEmpty {
                Section {
                    Text(status)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                } header: {
                    HeaderLabel(text: "Status", icon: "info.circle")
                }
            }
        }
        .navigationTitle("Control Center Editor")
        .onAppear {
            if mgr.sbxready {
                refreshAll()
            }
        }
        .onChange(of: mgr.sbxready) { ready in
            if ready {
                refreshAll()
            }
        }
        .alert("Reset Control Center Layout?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetToDefaults()
            }
        } message: {
            Text("If an original backup exists in Documents/lara_backups/cceditor/ it will be restored. Otherwise the editor's two keys are removed from the selected plist. A respring is offered afterwards.")
        }
    }

    // MARK: probe UI

    @ViewBuilder
    private var probeSection: some View {
        Section {
            if isLoading {
                HStack {
                    Text("Working...")
                    Spacer()
                    ProgressView()
                }
            }

            Button {
                refreshAll()
            } label: {
                Text("Probe preference locations again")
            }
            .disabled(isLoading)

            Button {
                UIPasteboard.general.string = probeSummary()
                status = "Probe summary copied to the clipboard."
            } label: {
                Text("Copy probe summary")
            }
            .disabled(sources.isEmpty)

            if sources.isEmpty && !isLoading {
                Text("No candidates have been probed yet.")
                    .foregroundColor(.secondary)
            }

            ForEach(sources) { source in
                Button {
                    if source.exists && source.readable {
                        selectSource(source)
                    }
                } label: {
                    probeRow(source)
                }
                .buttonStyle(.plain)
                .disabled(!source.exists || !source.readable || isLoading)
            }
        } header: {
            HeaderLabel(text: "Probe Results", icon: "magnifyingglass")
        } footer: {
            Text("Every candidate location is probed and logged. Tap a readable source to edit its keys. The iOS 26.0 path/schema is unconfirmed, so please report the found location back.")
                .font(.footnote)
        }
    }

    private func probeRow(_ source: CCEditorSource) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: source.exists ? (source.readable ? "doc.text.fill" : "exclamationmark.triangle") : "xmark.circle")
                .foregroundColor(source.exists ? (source.readable ? Color.green : Color.orange) : Color.secondary)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.label)
                    .font(.subheadline)
                Text(source.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)

                if let location = source.enabledKeyLocation {
                    Text("\(cceditorEnabledKey) at \(location) -> \(source.enabledCount ?? 0) module(s)")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else if source.readable {
                    Text("\(cceditorEnabledKey) not present in this file")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                if let error = source.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(3)
                }
            }

            Spacer()

            if activePath == source.path {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func sourceStateLabel(_ source: CCEditorSource) -> String {
        if !source.exists {
            return "[missing]"
        }
        return source.readable ? "[readable]" : "[exists]"
    }

    private func probeSummary() -> String {
        var lines: [String] = ["Control Center Editor probe summary"]
        for source in sources {
            var line = "\(sourceStateLabel(source)) \(source.path)"
            if let location = source.enabledKeyLocation {
                line += " | \(cceditorEnabledKey) at \(location) (\(source.enabledCount ?? 0) modules)"
            }
            if let location = source.disabledKeyLocation {
                line += " | \(cceditorDisabledKey) at \(location)"
            }
            if let error = source.error {
                line += " | error: \(error)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: editor UI

    @ViewBuilder
    private var editorSection: some View {
        Section {
            if let path = activePath {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Editing")
                        .font(.subheadline)
                    Text(path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }

                if enabledModules.isEmpty {
                    Text("The enabled module list is empty.")
                        .foregroundColor(.secondary)
                }

                ForEach(Array(enabledModules.enumerated()), id: \.element) { item in
                    HStack(spacing: 8) {
                        Text("\(item.offset + 1).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 24, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(friendlyName(for: item.element))
                            Text(item.element)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            moveModule(item.element, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoading || item.offset == 0)

                        Button {
                            moveModule(item.element, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoading || item.offset == enabledModules.count - 1)

                        Button(role: .destructive) {
                            removeModule(item.element)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoading)
                    }
                }
            } else {
                Text("No editable preference file selected. Pick a readable source in Probe Results above, or create the standard plist at the bottom.")
                    .foregroundColor(.secondary)
            }
        } header: {
            HeaderLabel(text: "Enabled Modules", icon: "square.grid.2x2")
        } footer: {
            Text("Order is written to \(cceditorEnabledKey). Removing a module also adds it to \(cceditorDisabledKey).")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var addSection: some View {
        Section {
            TextField("com.apple.control-center.CustomModule", text: $customIdentifier)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)

            Button {
                addModule(customIdentifier)
            } label: {
                Text("Add Custom Module")
            }
            .disabled(!canEdit || isLoading || customIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            HeaderLabel(text: "Add Module", icon: "plus.circle")
        } footer: {
            Text("The identifier is written exactly as typed. Unknown identifiers may be ignored by iOS; module identifiers from tweak bundles can be added here too.")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        Section {
            ForEach(cceditorModuleCatalog) { module in
                Button {
                    addModule(module.identifier)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.name)
                            Text(module.identifier)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text(module.detail)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if enabledModules.contains(module.identifier) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else if disabledModules.contains(module.identifier) {
                            Text("disabled")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        } else {
                            Image(systemName: "plus.circle")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canEdit || isLoading || enabledModules.contains(module.identifier))
            }
        } header: {
            HeaderLabel(text: "Known Modules", icon: "list.bullet")
        } footer: {
            Text("Verified iOS 26.0 identifiers are listed first. Accessibility modules are offered with and without the com.apple.control-center. prefix because the exact form is unconfirmed.")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var disabledSection: some View {
        if !disabledModules.isEmpty {
            Section {
                ForEach(disabledModules, id: \.self) { module in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friendlyName(for: module))
                            Text(module)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Re-enable") {
                            restoreModule(module)
                        }
                        .font(.caption)
                        .disabled(!canEdit || isLoading)
                    }
                }
            } header: {
                HeaderLabel(text: "Disabled by User", icon: "eye.slash")
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                applyChanges()
            } label: {
                Text("Apply Layout")
            }
            .disabled(!canEdit || isLoading)

            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Text("Reset to Defaults")
            }
            .disabled(!canEdit || isLoading)

            if sources.allSatisfy({ !$0.exists }) {
                Button {
                    createStandardSource()
                } label: {
                    Text("Use standard plist (create if missing)")
                }
                .disabled(!canProbe || isLoading)
            }
        } header: {
            HeaderLabel(text: "Actions", icon: "checkmark.circle")
        } footer: {
            Text("A backup is written to Documents/lara_backups/cceditor/ before every write. Applying offers a respring through lara's normal respring helper.")
                .font(.footnote)
        }
    }

    // MARK: probing

    private func refreshAll() {
        guard mgr.sbxready else {
            status = "Sandbox escape is not ready."
            return
        }

        isLoading = true
        defer { isLoading = false }

        let candidates = candidatePaths()
        globallogger.log("(cc) probing \(candidates.count) Control Center preference candidate(s)")

        var results: [CCEditorSource] = []
        for candidate in candidates {
            results.append(probeCandidate(path: candidate.path, label: candidate.label))
        }
        sources = results

        let readableCount = results.filter { $0.exists && $0.readable }.count
        globallogger.log("(cc) probe finished: \(readableCount) readable candidate(s)")

        if let current = activePath,
           let match = results.first(where: { $0.path == current && $0.exists && $0.readable }) {
            selectSource(match)
        } else if let best = results.first(where: { $0.exists && $0.readable && $0.enabledKeyLocation != nil })
                    ?? results.first(where: { $0.exists && $0.readable }) {
            selectSource(best)
        } else {
            clearEditor()
            status = "No existing Control Center preference file was found. Probe results are listed above; if this is expected, the standard plist can be created with the button below."
        }
    }

    private func candidatePaths() -> [(path: String, label: String)] {
        var candidates: [(path: String, label: String)] = [
            (cceditorStandardPath, "mobile Preferences / com.apple.ControlCenter.plist"),
            ("/var/mobile/Library/Preferences/com.apple.ControlCenterSettings.plist", "mobile Preferences / com.apple.ControlCenterSettings.plist"),
            ("/var/mobile/Library/Preferences/com.apple.ControlCenterUI.plist", "mobile Preferences / com.apple.ControlCenterUI.plist (extra guess)"),
            ("/var/mobile/Library/ControlCenter/ModuleConfiguration.plist", "mobile Library/ControlCenter / ModuleConfiguration.plist (extra guess)"),
            ("/var/Managed Preferences/mobile/com.apple.ControlCenter.plist", "managed Preferences / com.apple.ControlCenter.plist"),
        ]

        if let apps = mgr.getAppList() {
            for (bundleID, info) in apps where isControlCenterBundle(bundleID, info) {
                let label = "container \(bundleID)"

                if !info.dataFolder.isEmpty {
                    let dataRoot = "/var/mobile/Containers/Data/Application/\(info.dataFolder)"
                    candidates.append(("\(dataRoot)/Library/Preferences/ModuleConfiguration.plist", "\(label) / Preferences / ModuleConfiguration.plist"))
                    candidates.append(("\(dataRoot)/Library/Preferences/\(bundleID).plist", "\(label) / Preferences / \(bundleID).plist"))
                    candidates.append(("\(dataRoot)/Library/Preferences/com.apple.ControlCenter.plist", "\(label) / Preferences / com.apple.ControlCenter.plist"))
                    candidates.append(("\(dataRoot)/Library/ControlCenter/ModuleConfiguration.plist", "\(label) / Library/ControlCenter / ModuleConfiguration.plist"))
                    candidates.append(contentsOf: discoveredPlists(in: "\(dataRoot)/Library/Preferences", label: "\(label) / Preferences scan"))
                }

                if !info.bundleFolder.isEmpty {
                    let bundleRoot = "/var/containers/Bundle/Application/\(info.bundleFolder)"
                    candidates.append(("\(bundleRoot)/ModuleConfiguration.plist", "\(label) bundle / ModuleConfiguration.plist"))
                    candidates.append(contentsOf: bundleModuleConfigs(in: bundleRoot, label: label))
                }
            }
        }

        var seen = Set<String>()
        var unique: [(path: String, label: String)] = []
        for candidate in candidates where !seen.contains(candidate.path) {
            seen.insert(candidate.path)
            unique.append(candidate)
        }
        return unique
    }

    private func isControlCenterBundle(_ bundleID: String, _ info: laramgr.AppInfo) -> Bool {
        let needles = ["controlcenter", "control-center", "controlcentre", "control center", "control centre"]
        let haystacks = [bundleID, info.executable, info.displayName, info.bundleName]
        for haystack in haystacks {
            let lower = haystack.lowercased()
            for needle in needles where lower.contains(needle) {
                return true
            }
        }
        return false
    }

    private func discoveredPlists(in directory: String, label: String) -> [(path: String, label: String)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var found: [(path: String, label: String)] = []
        for entry in entries {
            let lower = entry.lowercased()
            guard lower.hasSuffix(".plist") else { continue }
            guard lower.contains("control") || lower.contains("module") else { continue }
            found.append(("\(directory)/\(entry)", "\(label) / \(entry)"))
        }
        return found
    }

    private func bundleModuleConfigs(in bundleRoot: String, label: String) -> [(path: String, label: String)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: bundleRoot) else {
            return []
        }
        var found: [(path: String, label: String)] = []
        for entry in entries where entry.hasSuffix(".app") {
            found.append(("\(bundleRoot)/\(entry)/ModuleConfiguration.plist", "\(label) bundle / \(entry) / ModuleConfiguration.plist"))
        }
        return found
    }

    private func probeCandidate(path: String, label: String) -> CCEditorSource {
        var source = CCEditorSource(
            path: path,
            label: label,
            exists: false,
            readable: false,
            topLevelKeys: [],
            enabledKeyLocation: nil,
            disabledKeyLocation: nil,
            enabledCount: nil,
            error: nil
        )

        source.exists = FileManager.default.fileExists(atPath: path)
        globallogger.log("(cc) probe \(path): \(source.exists ? "exists" : "not found")")
        guard source.exists else { return source }

        do {
            let dict = try readPlistDictionary(path: path)
            source.readable = true
            source.topLevelKeys = dict.allKeys.compactMap { $0 as? String }

            if let located = findKeyPath(cceditorEnabledKey, in: dict) {
                source.enabledKeyLocation = located.joined(separator: " > ")
                source.enabledCount = strings(from: pathValue(at: located, in: dict)).count
                globallogger.log("(cc) found \(cceditorEnabledKey) at \(source.enabledKeyLocation ?? "") with \(source.enabledCount ?? 0) module(s)")
            }

            if let located = findKeyPath(cceditorDisabledKey, in: dict) {
                source.disabledKeyLocation = located.joined(separator: " > ")
                globallogger.log("(cc) found \(cceditorDisabledKey) at \(located.joined(separator: " > "))")
            }

            if source.enabledKeyLocation == nil {
                globallogger.log("(cc) \(cceditorEnabledKey) not present in \(path); top-level keys: \(source.topLevelKeys.joined(separator: ", "))")
            }
        } catch {
            source.error = "\(error)"
            globallogger.log("(cc) read failed for \(path): \(error)")
        }

        return source
    }

    // MARK: reading

    private func readPlistDictionary(path: String) throws -> NSMutableDictionary {
        do {
            return try loadMutablePlistDictionary(from: URL(fileURLWithPath: path))
        } catch {
            // Fall back to VFS reads if the sandbox escape cannot read the file.
            if mgr.vfsready, let data = mgr.vfsread(path: path) {
                var format = PropertyListSerialization.PropertyListFormat.binary
                let plist = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [.mutableContainersAndLeaves],
                    format: &format
                )
                guard let dict = plist as? NSMutableDictionary else {
                    throw "Property list root is not a dictionary."
                }
                globallogger.log("(cc) read \(path) through the VFS fallback")
                return dict
            }
            throw error
        }
    }

    private func selectSource(_ source: CCEditorSource) {
        do {
            let dict = try readPlistDictionary(path: source.path)
            activePath = source.path
            enabledModules = strings(from: pathValue(at: findKeyPath(cceditorEnabledKey, in: dict) ?? [cceditorEnabledKey], in: dict))
            disabledModules = strings(from: pathValue(at: findKeyPath(cceditorDisabledKey, in: dict) ?? [cceditorDisabledKey], in: dict))
            globallogger.log("(cc) editing \(source.path): \(enabledModules.count) enabled / \(disabledModules.count) disabled module(s)")
            status = "Loaded \(source.path). \(enabledModules.count) enabled module(s)."
        } catch {
            clearEditor()
            status = "Failed to read \(source.path): \(error)"
            globallogger.log("(cc) select source failed for \(source.path): \(error)")
        }
    }

    private func clearEditor() {
        activePath = nil
        enabledModules = []
        disabledModules = []
    }

    // MARK: editing

    private func createStandardSource() {
        activePath = cceditorStandardPath
        enabledModules = []
        disabledModules = []
        status = "Standard plist selected: \(cceditorStandardPath). Applying will create it with the editor's keys."
        globallogger.log("(cc) create-standard-source: \(cceditorStandardPath)")
    }

    private func addModule(_ rawIdentifier: String) {
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return }
        guard !enabledModules.contains(identifier) else {
            status = "\(identifier) is already in the enabled list."
            return
        }
        enabledModules.append(identifier)
        disabledModules.removeAll { $0 == identifier }
        customIdentifier = ""
        globallogger.log("(cc) staged add: \(identifier)")
    }

    private func removeModule(_ identifier: String) {
        enabledModules.removeAll { $0 == identifier }
        if !disabledModules.contains(identifier) {
            disabledModules.append(identifier)
        }
        globallogger.log("(cc) staged remove: \(identifier)")
    }

    private func restoreModule(_ identifier: String) {
        disabledModules.removeAll { $0 == identifier }
        if !enabledModules.contains(identifier) {
            enabledModules.append(identifier)
        }
        globallogger.log("(cc) staged re-enable: \(identifier)")
    }

    private func moveModule(_ identifier: String, by offset: Int) {
        guard let index = enabledModules.firstIndex(of: identifier) else { return }
        let destination = index + offset
        guard destination >= 0, destination < enabledModules.count else { return }
        enabledModules.swapAt(index, destination)
        globallogger.log("(cc) staged reorder: \(identifier) \(offset < 0 ? "up" : "down")")
    }

    private func friendlyName(for identifier: String) -> String {
        if let known = cceditorModuleCatalog.first(where: { $0.identifier == identifier }) {
            return known.name
        }
        if let last = identifier.split(separator: ".").last {
            return String(last)
        }
        return identifier
    }

    // MARK: writing

    private func applyChanges() {
        guard mgr.sbxready else {
            status = "Sandbox escape is not ready."
            return
        }
        guard let path = activePath else {
            status = "No editable source selected."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            var dict = NSMutableDictionary()
            if FileManager.default.fileExists(atPath: path) {
                dict = try readPlistDictionary(path: path)
            } else {
                globallogger.log("(cc) \(path) does not exist; creating a new plist")
            }

            let enabledPath = findKeyPath(cceditorEnabledKey, in: dict) ?? [cceditorEnabledKey]
            let disabledPath = findKeyPath(cceditorDisabledKey, in: dict) ?? [cceditorDisabledKey]
            setPathValue(enabledModules, at: enabledPath, in: dict)
            setPathValue(disabledModules, at: disabledPath, in: dict)

            let notes = try backupBeforeWrite(path: path)
            for note in notes {
                globallogger.log("(cc) backup: \(note)")
            }

            let data = try verifyPlist(dict, targetPath: path)
            globallogger.log("(cc) writing \(enabledModules.count) enabled + \(disabledModules.count) disabled module(s) to \(path)")
            let result = mgr.lara_overwritefile(target: path, data: data)
            guard result.ok else {
                throw "Overwrite failed: \(result.message)"
            }

            globallogger.log("(cc) write ok: \(result.message)")
            refreshAll()
            status = "Applied layout to \(path)."

            Alertinator.shared.alert(
                title: "Control Center layout applied",
                body: "Respring to see the new layout. If nothing changes, the on-disk schema may differ from the guesses documented in docs/dev/cceditor-integration.md.",
                actionLabel: "Respring",
                action: { mgr.respring() }
            )
        } catch {
            globallogger.log("(cc) apply failed: \(error)")
            status = "Apply failed: \(error)"
            Alertinator.shared.alert(title: "Failed to apply Control Center layout", body: "\(error)")
        }
    }

    private func resetToDefaults() {
        guard mgr.sbxready else {
            status = "Sandbox escape is not ready."
            return
        }
        guard let path = activePath else {
            status = "No editable source selected."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let original = try originalBackupURL(for: path)
            if FileManager.default.fileExists(atPath: original.path) {
                let data = try Data(contentsOf: original)
                _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

                let notes = try backupBeforeWrite(path: path)
                for note in notes {
                    globallogger.log("(cc) backup: \(note)")
                }

                let result = mgr.lara_overwritefile(target: path, data: data)
                guard result.ok else {
                    throw "Overwrite failed: \(result.message)"
                }

                globallogger.log("(cc) restored original backup for \(path)")
                refreshAll()
                status = "Restored the original backup for \(path)."
                respringAlert(title: "Control Center layout reset", body: "The original preference file was restored from Documents/lara_backups/cceditor/. Respring to apply.")
                return
            }

            guard FileManager.default.fileExists(atPath: path) else {
                status = "\(path) does not exist and there is no original backup, so there is nothing to reset."
                return
            }

            var dict = try readPlistDictionary(path: path)

            let notes = try backupBeforeWrite(path: path)
            for note in notes {
                globallogger.log("(cc) backup: \(note)")
            }

            var removed: [String] = []
            if let located = findKeyPath(cceditorEnabledKey, in: dict), removePathValue(at: located, in: dict) {
                removed.append(located.joined(separator: " > "))
            }
            if let located = findKeyPath(cceditorDisabledKey, in: dict), removePathValue(at: located, in: dict) {
                removed.append(located.joined(separator: " > "))
            }

            let data = try verifyPlist(dict, targetPath: path)
            let result = mgr.lara_overwritefile(target: path, data: data)
            guard result.ok else {
                throw "Overwrite failed: \(result.message)"
            }

            globallogger.log("(cc) removed editor keys from \(path): \(removed.joined(separator: ", "))")
            refreshAll()
            status = removed.isEmpty
                ? "No editor keys were present in \(path); nothing was removed."
                : "Removed editor keys from \(path): \(removed.joined(separator: ", "))."
            respringAlert(title: "Control Center layout reset", body: "The editor's keys were removed from the preference file. Respring to apply.")
        } catch {
            globallogger.log("(cc) reset failed: \(error)")
            status = "Reset failed: \(error)"
            Alertinator.shared.alert(title: "Failed to reset Control Center layout", body: "\(error)")
        }
    }

    private func respringAlert(title: String, body: String) {
        Alertinator.shared.alert(title: title, body: body, actionLabel: "Respring", action: { mgr.respring() })
    }

    // MARK: backups

    private func backupBeforeWrite(path: String) throws -> [String] {
        let fm = FileManager.default
        let dir = try backupsDirectory()
        let safe = backupFileName(for: path)
        var notes: [String] = []

        guard fm.fileExists(atPath: path) else {
            notes.append("nothing to back up for \(path) (file does not exist yet)")
            return notes
        }

        let stamp = backupTimestamp()
        var snapshot = dir.appendingPathComponent("snapshot-\(stamp)-\(safe)")
        if fm.fileExists(atPath: snapshot.path) {
            snapshot = dir.appendingPathComponent("snapshot-\(stamp)-\(UUID().uuidString.prefix(4))-\(safe)")
        }
        do {
            try fm.copyItem(atPath: path, toPath: snapshot.path)
            notes.append("snapshot: \(snapshot.lastPathComponent)")
        } catch {
            notes.append("snapshot failed: \(error.localizedDescription)")
        }

        let original = dir.appendingPathComponent("orig-\(safe)")
        if !fm.fileExists(atPath: original.path) {
            do {
                try fm.copyItem(atPath: path, toPath: original.path)
                notes.append("original backup: \(original.lastPathComponent)")
            } catch {
                notes.append("original backup failed: \(error.localizedDescription)")
            }
        } else {
            notes.append("original backup already exists: \(original.lastPathComponent)")
        }

        return notes
    }

    private func backupsDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs
            .appendingPathComponent("lara_backups", isDirectory: true)
            .appendingPathComponent("cceditor", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func originalBackupURL(for path: String) throws -> URL {
        try backupsDirectory().appendingPathComponent("orig-\(backupFileName(for: path))")
    }

    private func backupFileName(for path: String) -> String {
        var name = path
        if name.hasPrefix("/") {
            name.removeFirst()
        }
        name = name.replacingOccurrences(of: "/", with: "_")
        name = name.replacingOccurrences(of: " ", with: "-")
        return name.isEmpty ? "com.apple.ControlCenter.plist" : name
    }

    private func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: plist helpers
    //
    // The real schema is unknown, so keys are looked up recursively and are
    // updated wherever they live. If a key cannot be found, it is created at
    // the top level of the selected plist (the researched layout).

    private func findKeyPath(_ key: String, in dict: NSDictionary) -> [String]? {
        if dict[key] != nil {
            return [key]
        }
        for (rawKey, rawValue) in dict {
            guard let childKey = rawKey as? String, let child = rawValue as? NSDictionary else { continue }
            if let found = findKeyPath(key, in: child) {
                return [childKey] + found
            }
        }
        return nil
    }

    private func pathValue(at path: [String], in dict: NSDictionary) -> Any? {
        guard let first = path.first else { return nil }
        if path.count == 1 {
            return dict[first]
        }
        guard let child = dict[first] as? NSDictionary else { return nil }
        return pathValue(at: Array(path.dropFirst()), in: child)
    }

    @discardableResult
    private func setPathValue(_ value: Any, at path: [String], in dict: NSMutableDictionary) -> Bool {
        guard let first = path.first else { return false }
        if path.count == 1 {
            dict[first] = value
            return true
        }

        let rest = Array(path.dropFirst())
        if let child = dict[first] as? NSMutableDictionary {
            return setPathValue(value, at: rest, in: child)
        }
        if let child = dict[first] as? NSDictionary {
            let mutable = NSMutableDictionary(dictionary: child)
            dict[first] = mutable
            return setPathValue(value, at: rest, in: mutable)
        }

        let newChild = NSMutableDictionary()
        dict[first] = newChild
        return setPathValue(value, at: rest, in: newChild)
    }

    @discardableResult
    private func removePathValue(at path: [String], in dict: NSMutableDictionary) -> Bool {
        guard let first = path.first else { return false }
        if path.count == 1 {
            guard dict[first] != nil else { return false }
            dict.removeObject(forKey: first)
            return true
        }
        guard let child = dict[first] as? NSMutableDictionary else { return false }
        return removePathValue(at: Array(path.dropFirst()), in: child)
    }

    private func strings(from value: Any?) -> [String] {
        guard let value = value else { return [] }

        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else if let array = value as? NSArray {
            items = array.map { $0 }
        } else {
            return []
        }

        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            guard let string = item as? String, !string.isEmpty else { continue }
            if seen.insert(string).inserted {
                result.append(string)
            }
        }
        return result
    }
}

#Preview {
    NavigationStack {
        CCEditorView(mgr: laramgr.shared)
    }
}
