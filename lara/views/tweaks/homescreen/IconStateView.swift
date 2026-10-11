//
//  IconStateView.swift
//  lara
//
//  Home Screen Icon Toolbox.
//  Extends the GlobalPreferences / SBIconVisibility technique used by
//  ShowHiddenIconsView, and adds backup / restore / reset handling for
//  SpringBoard's icon state files.
//
//  The global preference surface, the gate and the safety backup pattern are
//  deliberately modelled on views/tweaks/ShowHiddenIconsView.swift.
//

import SwiftUI
import UIKit

private struct iconsourcefile: Identifiable {
    let name: String
    let path: String
    let resetremoves: Bool

    var id: String { name }
}

private struct iconstateappentry: Identifiable, Hashable {
    let id: String
    let name: String
}

private struct iconbackupentry: Identifiable {
    let id: String
    let url: URL
    let date: Date
    let filecount: Int
    let bytes: Int64
}

private let iconstatebackupfolder = "lara_backups"

private let iconsourcefiles: [iconsourcefile] = [
    iconsourcefile(name: "IconState.plist", path: "/var/mobile/Library/SpringBoard/IconState.plist", resetremoves: true),
    iconsourcefile(name: "DesiredIconState.plist", path: "/var/mobile/Library/SpringBoard/DesiredIconState.plist", resetremoves: true),
    iconsourcefile(name: "applicationState.db", path: "/var/mobile/Library/FrontBoard/applicationState.db", resetremoves: false),
    iconsourcefile(name: "applicationState.db-wal", path: "/var/mobile/Library/FrontBoard/applicationState.db-wal", resetremoves: false),
    iconsourcefile(name: "applicationState.db-shm", path: "/var/mobile/Library/FrontBoard/applicationState.db-shm", resetremoves: false),
]

private let iconstatebackupstamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
}()

struct IconStateView: View {
    @ObservedObject var mgr: laramgr

    // Same preference surface as ShowHiddenIconsView.
    private let globalprefspath = fileloc.globalprefs.rawValue
    private let visibilitykey = "SBIconVisibility"

    // Bundle IDs this tool has flagged as hidden, persisted as a JSON array.
    @AppStorage("lara.iconstate.trackedhidden") private var trackedjson: String = "[]"

    @State private var isLoading = false
    @State private var status: String?
    @State private var revealenabled = false
    @State private var filesizes: [String: Int64] = [:]
    @State private var bundlecount = 0
    @State private var containercount = 0
    @State private var apps: [iconstateappentry] = []
    @State private var backupentries: [iconbackupentry] = []
    @State private var confirmreset = false
    @State private var pendingrestore: iconbackupentry?
    @State private var pendingunhide: String?

    private let systemcriticalids: Set<String> = [
        "com.apple.springboard",
        "com.apple.Preferences",
        "com.apple.mobilephone",
        "com.apple.InCallService",
        "com.apple.purplebuddy",
        "com.apple.ScreenTimeAgent",
    ]

    private let systemcriticalprefixes: [String] = [
        "com.apple.springboard",
    ]

    private var backuproot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(iconstatebackupfolder, isDirectory: true)
    }

    private var canWrite: Bool { mgr.sbxready }
    private var canRead: Bool { mgr.sbxready || mgr.vfsready }

    private var trackedids: [String] {
        guard let data = trackedjson.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    private var hidecandidates: [iconstateappentry] {
        let ownbundle = Bundle.main.bundleIdentifier
        let tracked = trackedids
        return apps.filter { app in
            app.id != ownbundle
                && !tracked.contains(app.id)
                && !issystemcritical(app.id)
        }
    }

    private var restorebinding: Binding<Bool> {
        Binding(
            get: { pendingrestore != nil },
            set: { if !$0 { pendingrestore = nil } }
        )
    }

    private var unhidebinding: Binding<Bool> {
        Binding(
            get: { pendingunhide != nil },
            set: { if !$0 { pendingunhide = nil } }
        )
    }

    var body: some View {
        List {
            statussection
            visibilitysection
            backupsection
            resetsection
        }
        .navigationTitle("Icon Toolbox")
        .onAppear {
            loadall()
        }
        .alert("Icon Toolbox", isPresented: .constant(status != nil)) {
            Button("OK") { status = nil }
        } message: {
            Text(status ?? "")
        }
        .alert("Restore Backup?", isPresented: restorebinding) {
            Button("Cancel", role: .cancel) { pendingrestore = nil }
            Button("Restore", role: .destructive) {
                if let backup = pendingrestore {
                    pendingrestore = nil
                    restore(backup)
                }
            }
        } message: {
            Text("Overwrites IconState.plist, DesiredIconState.plist and applicationState.db (plus -wal/-shm when the backup contains them) with the selected backup. A safety backup of the current state is written first, and a respring is needed afterwards. If the restored applicationState.db does not match the live -wal/-shm files, reboot instead of respringing.")
        }
        .alert("Unhide App?", isPresented: unhidebinding) {
            Button("Cancel", role: .cancel) { pendingunhide = nil }
            Button("Unhide") {
                if let bundleid = pendingunhide {
                    pendingunhide = nil
                    unhideapp(bundleid)
                }
            }
        } message: {
            Text("Removes the app from this tool's hidden list and restores the default SBIconVisibility preference. A safety backup is written first. If iOS itself hid the app, use the App Library Hidden folder or Show Hidden Icons to make it visible again.")
        }
        .alert("Reset Home Screen Layout?", isPresented: $confirmreset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetlayout()
            }
        } message: {
            Text("Deletes IconState.plist and DesiredIconState.plist after writing a safety backup, clears the SBIconVisibility preference and this tool's hidden list, then resprings SpringBoard. SpringBoard rebuilds a default layout, so pages, folders and icon positions will be lost. SpringBoard's applicationState.db is not touched (see Show Hidden Icons for that).")
        }
    }

    private var statussection: some View {
        Section(
            header: HeaderLabel(text: "Status", icon: "info.circle"),
            footer: Text("Icon state files are read through the sandbox escape with a VFS fallback. Every write, restore and reset is gated on the sandbox escape being ready.")
        ) {
            HStack {
                Text("Sandbox escape")
                Spacer()
                Text(mgr.sbxready ? "ready" : "not ready")
                    .foregroundColor(mgr.sbxready ? .green : .red)
                    .monospaced()
            }

            HStack {
                Text("VFS (read fallback)")
                Spacer()
                Text(mgr.vfsready ? "ready" : "not ready")
                    .foregroundColor(mgr.vfsready ? .green : .secondary)
                    .monospaced()
            }

            ForEach(iconsourcefiles) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                        Text(file.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if let size = filesizes[file.name] {
                        Text(bytesstring(size))
                            .foregroundColor(.secondary)
                            .monospaced()
                    } else {
                        Text("missing")
                            .foregroundColor(.orange)
                    }
                }
            }

            HStack {
                Text("Installed app bundles")
                Spacer()
                Text("\(bundlecount)")
                    .foregroundColor(.secondary)
                    .monospaced()
            }

            HStack {
                Text("App data containers")
                Spacer()
                Text("\(containercount)")
                    .foregroundColor(.secondary)
                    .monospaced()
            }

            Button {
                loadall()
            } label: {
                if isLoading {
                    HStack {
                        Text("Refreshing...")
                        Spacer()
                        ProgressView()
                    }
                } else {
                    Text("Refresh Status")
                }
            }
            .disabled(isLoading)
        }
    }

    private var visibilitysection: some View {
        Section(
            header: HeaderLabel(text: "App Visibility", icon: "eye.slash"),
            footer: Text("Uses the same GlobalPreferences key as Show Hidden Icons, inverted: clearing SBIconVisibility stops SpringBoard from revealing hidden icons. Lara cannot create SpringBoard's own per-app hidden state, so marking an app here records the bundle ID and applies the hide state; iOS' Hide App remains the supported way to truly hide an app.")
        ) {
            HStack {
                Text("SBIconVisibility")
                Spacer()
                Text(revealenabled ? "on (hidden icons revealed)" : "off (hidden icons stay hidden)")
                    .foregroundColor(revealenabled ? .orange : .secondary)
                    .monospaced()
            }

            HStack {
                NavigationLink(destination: IconStateAppPickerView(apps: hidecandidates, onhide: { app in
                    return hideapp(app)
                })) {
                    HStack {
                        Text("Hide an App")
                        Spacer()
                        Text("\(hidecandidates.count)")
                            .foregroundColor(.secondary)
                            .monospaced()
                    }
                }
                .disabled(isLoading || !canWrite)

                Spacer()

                Button {
                    Alertinator.shared.alert(
                        title: "Hide an App",
                        body: "Picking an app writes a safety backup, records the bundle ID in this tool and clears the SBIconVisibility reveal preference. If the app was never hidden by iOS it will stay on the Home Screen; use the App Library's Hide and Require Face ID to truly hide it, then this tool can keep the reveal preference from undoing that."
                    )
                } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
            }

            if trackedids.isEmpty {
                Text("No apps marked hidden by this tool.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(trackedids, id: \.self) { bundleid in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appname(for: bundleid))
                            Text(bundleid)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Unhide") {
                            pendingunhide = bundleid
                        }
                        .disabled(isLoading || !canWrite)
                    }
                }
            }
        }
    }

    private var backupsection: some View {
        Section(
            header: HeaderLabel(text: "Backups", icon: "externaldrive"),
            footer: Text("Backups are written to Documents/lara_backups/<prefix>-<timestamp>/. Each folder contains IconState.plist, DesiredIconState.plist and applicationState.db (+ -wal/-shm when present) plus a manifest. Restoring overwrites the live files and requires a respring; a safety backup of the current state is always written first.")
        ) {
            Button {
                manualbackup()
            } label: {
                Text("Back Up Icon State Now")
            }
            .disabled(isLoading || !canWrite)

            if backupentries.isEmpty {
                Text("No backups yet.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(backupentries) { backup in
                    Button {
                        pendingrestore = backup
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.id)
                                Text("\(backup.filecount) file(s) · \(bytesstring(backup.bytes)) · \(backup.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.counterclockwise.circle")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading || !canWrite)
                }
            }
        }
    }

    private var resetsection: some View {
        Section(
            header: HeaderLabel(text: "Reset", icon: "exclamationmark.triangle"),
            footer: Text("The reset only removes the home screen layout files. SpringBoard's applicationState.db and the SBIconVisibility preference handling stay available in Show Hidden Icons. If the layout does not come back after a respring, reboot the device.")
        ) {
            HStack {
                Button(role: .destructive) {
                    confirmreset = true
                } label: {
                    Text("Reset Home Screen Layout")
                }
                .disabled(isLoading || !canWrite)

                Spacer()

                Button {
                    Alertinator.shared.alert(
                        title: "Reset Home Screen Layout",
                        body: "This deletes SpringBoard's cached home screen layout files and lets SpringBoard recreate the default layout on respring. Pages, folders and icon positions are lost, including apps this tool was tracking as hidden. A safety backup is written first and can be restored from the Backups section."
                    )
                } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - state

    private func loadall() {
        isLoading = true
        defer { isLoading = false }

        if !canRead {
            mgr.logmsg("(icons) neither the sandbox escape nor VFS is ready; icon state files may be unreadable")
        }

        // Same read as ShowHiddenIconsView.loadState().
        let pref = mgr.getplistvalue(path: globalprefspath, key: visibilitykey)
        if pref.ok, let value = pref.value as? Bool {
            revealenabled = value
        } else {
            revealenabled = false
        }

        var sizes: [String: Int64] = [:]
        for file in iconsourcefiles {
            if let size = filesize(file.path) {
                sizes[file.name] = size
            }
        }
        filesizes = sizes

        var bundles = 0
        var containers = 0
        var entries: [iconstateappentry] = []
        if let list = mgr.getAppList() {
            for (bundleid, info) in list {
                guard !bundleid.isEmpty else { continue }
                if !info.dataFolder.isEmpty { containers += 1 }
                guard !info.bundleFolder.isEmpty else { continue }
                let name = info.displayName.isEmpty ? info.bundleName : info.displayName
                guard !name.isEmpty else { continue }
                entries.append(iconstateappentry(id: bundleid, name: name))
                bundles += 1
            }
        } else {
            mgr.logmsg("(icons) failed to enumerate installed apps")
        }
        apps = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        bundlecount = bundles
        containercount = containers
        backupentries = loadbackups()
    }

    // MARK: - hide / unhide

    private func hideapp(_ app: iconstateappentry) -> (ok: Bool, message: String) {
        guard canWrite else {
            return (false, "Sandbox escape is not ready.")
        }

        guard let backupid = makebackup(prefix: "pre-hide") else {
            return (false, "Hide aborted: the safety backup could not be created.")
        }

        // Inverse of ShowHiddenIconsView.setEnabled(true): remove the key instead
        // of revealing hidden icons.
        let result = mgr.setplistvalue(path: globalprefspath, key: (visibilitykey, nil), force: true)
        guard result.ok else {
            mgr.logmsg("(icons) failed to clear SBIconVisibility for \(app.id): \(result.message)")
            return (false, "Could not update SBIconVisibility: \(result.message)\nA safety backup was saved as \(backupid).")
        }

        var ids = trackedids
        if !ids.contains(app.id) {
            ids.append(app.id)
        }
        settracked(ids)
        revealenabled = false

        mgr.logmsg("(icons) marked \(app.id) as hidden and cleared SBIconVisibility (backup: \(backupid))")
        return (true, "\(app.name) is now flagged as hidden and the reveal preference was cleared, so SpringBoard will not force hidden icons back onto the Home Screen. If the icon is still visible, iOS is not hiding the app; use the App Library's Hide and Require Face ID, or reset the layout.")
    }

    private func unhideapp(_ bundleid: String) {
        guard canWrite else {
            status = "Sandbox escape is not ready."
            return
        }

        guard let backupid = makebackup(prefix: "pre-unhide") else {
            status = "Unhide aborted: the safety backup could not be created."
            return
        }

        var ids = trackedids
        ids.removeAll { $0 == bundleid }
        settracked(ids)

        var preferencemessage = ""
        if ids.isEmpty {
            let result = mgr.setplistvalue(path: globalprefspath, key: (visibilitykey, nil), force: true)
            if result.ok {
                revealenabled = false
                preferencemessage = " The reveal preference is back at its default value."
            } else {
                preferencemessage = " The reveal preference could not be updated: \(result.message)"
            }
        }

        mgr.logmsg("(icons) removed \(bundleid) from the hidden list (backup: \(backupid)).\(preferencemessage)")
        status = "\(appname(for: bundleid)) is no longer flagged as hidden.\(preferencemessage)"
    }

    // MARK: - backups

    private func manualbackup() {
        guard canWrite else {
            status = "Sandbox escape is not ready."
            return
        }

        guard let backupid = makebackup(prefix: "manual") else {
            status = "Backup failed. See the log for details."
            return
        }

        let entry = loadbackups().first { $0.id == backupid }
        let copied = max((entry?.filecount ?? 1) - 1, 0)
        if copied == 0 {
            status = "Backup \(backupid) was written, but none of the icon state files could be read."
        } else {
            status = "Backup \(backupid) was written with \(copied) file(s)."
        }
    }

    @discardableResult
    private func makebackup(prefix: String) -> String? {
        guard canWrite else { return nil }

        let fm = FileManager.default
        let folder = backuproot.appendingPathComponent("\(prefix)-\(iconstatebackupstamp.string(from: Date()))", isDirectory: true)

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)

            var manifestfiles: [[String: Any]] = []
            var copied = 0
            for source in iconsourcefiles {
                guard let data = readdevicefile(source.path) else {
                    manifestfiles.append([
                        "name": source.name,
                        "path": source.path,
                        "exists": false,
                        "bytes": 0,
                    ])
                    continue
                }
                try data.write(to: folder.appendingPathComponent(source.name), options: .atomic)
                manifestfiles.append([
                    "name": source.name,
                    "path": source.path,
                    "exists": true,
                    "bytes": data.count,
                ])
                copied += 1
            }

            let manifest: [String: Any] = [
                "created": Date(),
                "iosversion": UIDevice.current.systemVersion,
                "prefix": prefix,
                "files": manifestfiles,
            ]
            if let manifestdata = try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0) {
                try? manifestdata.write(to: folder.appendingPathComponent("manifest.plist"), options: .atomic)
            }

            mgr.logmsg("(icons) backup \(folder.lastPathComponent) written (\(copied) file(s))")
            backupentries = loadbackups()
            return folder.lastPathComponent
        } catch {
            mgr.logmsg("(icons) backup failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func restore(_ backup: iconbackupentry) {
        guard canWrite else {
            status = "Sandbox escape is not ready."
            return
        }

        guard makebackup(prefix: "pre-restore") != nil else {
            status = "Restore aborted: the safety backup could not be created."
            return
        }

        globallogger.divider()
        mgr.logmsg("(icons) restoring backup \(backup.id)")

        let fm = FileManager.default
        var restored: [String] = []
        var failures: [String] = []

        for source in iconsourcefiles {
            let backupfile = backup.url.appendingPathComponent(source.name)
            guard fm.fileExists(atPath: backupfile.path) else { continue }
            guard let data = try? Data(contentsOf: backupfile) else {
                failures.append("\(source.name): backup file unreadable")
                continue
            }

            let result = mgr.lara_overwritefile(target: source.path, data: data)
            if result.ok {
                restored.append(source.name)
            } else {
                failures.append("\(source.name): \(result.message)")
            }
        }

        if restored.isEmpty && failures.isEmpty {
            status = "Nothing to restore from \(backup.id): no known icon state files were found in that backup."
            return
        }

        if failures.isEmpty {
            mgr.logmsg("(icons) restored \(restored.count) file(s) from \(backup.id)")
            Alertinator.shared.alert(
                title: "Backup Restored",
                body: "Restored \(restored.joined(separator: ", ")) from \(backup.id).\n\nRespring SpringBoard so it reloads the restored icon state. If applicationState.db was restored, reboot instead of respringing so the database and its -wal/-shm files are consistent.",
                actionLabel: "Respring",
                action: { mgr.respring() }
            )
        } else {
            mgr.logmsg("(icons) restore from \(backup.id) failed: \(failures.joined(separator: " | "))")
            status = "Restore finished with problems:\n" + failures.joined(separator: "\n")
        }

        loadall()
    }

    // MARK: - reset

    private func resetlayout() {
        guard canWrite else {
            status = "Sandbox escape is not ready."
            return
        }

        guard let backupid = makebackup(prefix: "pre-reset") else {
            status = "Reset aborted: the safety backup could not be created."
            return
        }

        globallogger.divider()
        mgr.logmsg("(icons) resetting home screen layout (backup: \(backupid))")

        let fm = FileManager.default
        var removed: [String] = []
        var failures: [String] = []

        for source in iconsourcefiles where source.resetremoves {
            do {
                if fm.fileExists(atPath: source.path) {
                    try fm.removeItem(atPath: source.path)
                    removed.append(source.name)
                }
            } catch {
                failures.append("\(source.name): \(error.localizedDescription)")
            }
        }

        // Drop the reveal preference and this tool's tracking so nothing is re-applied
        // to the freshly rebuilt layout.
        let preference = mgr.setplistvalue(path: globalprefspath, key: (visibilitykey, nil), force: true)
        settracked([])
        revealenabled = false

        if failures.isEmpty {
            mgr.logmsg("(icons) layout reset: removed \(removed.joined(separator: ", ")); backup \(backupid); SBIconVisibility cleared (\(preference.message))")
            Alertinator.shared.alert(
                title: "Layout Reset",
                body: "Removed \(removed.isEmpty ? "no files (they were already missing)" : removed.joined(separator: ", ")).\n\nSpringBoard rebuilds the default layout on respring. A safety backup was saved as \(backupid).",
                actionLabel: "Respring",
                action: { mgr.respring() }
            )
        } else {
            mgr.logmsg("(icons) layout reset failed: \(failures.joined(separator: " | "))")
            status = "Reset finished with problems:\n" + failures.joined(separator: "\n")
        }

        loadall()
    }

    // MARK: - helpers

    private func appname(for bundleid: String) -> String {
        apps.first { $0.id == bundleid }?.name ?? bundleid
    }

    private func settracked(_ ids: [String]) {
        if let data = try? JSONEncoder().encode(ids),
           let json = String(data: data, encoding: .utf8) {
            trackedjson = json
        }
    }

    private func issystemcritical(_ bundleid: String) -> Bool {
        if systemcriticalids.contains(bundleid) { return true }
        return systemcriticalprefixes.contains { bundleid.hasPrefix($0) }
    }

    private func filesize(_ path: String) -> Int64? {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }
        if mgr.vfsready {
            let size = mgr.vfssize(path: path)
            return size >= 0 ? size : nil
        }
        return nil
    }

    private func readdevicefile(_ path: String) -> Data? {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return data
        }
        return mgr.vfsread(path: path, maxSize: 64 * 1024 * 1024)
    }

    private func loadbackups() -> [iconbackupentry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: backuproot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [iconbackupentry] = []
        for url in items {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }

            let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            var bytes: Int64 = 0
            for file in files {
                bytes += filesize(url.appendingPathComponent(file).path) ?? 0
            }

            entries.append(iconbackupentry(
                id: url.lastPathComponent,
                url: url,
                date: values?.contentModificationDate ?? Date.distantPast,
                filecount: files.count,
                bytes: bytes
            ))
        }

        return entries.sorted { $0.date > $1.date }
    }

    private func bytesstring(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct IconStateAppPickerView: View {
    let apps: [iconstateappentry]
    let onhide: (iconstateappentry) -> (ok: Bool, message: String)

    @State private var search = ""
    @State private var pending: iconstateappentry?
    @State private var locallyhidden: Set<String> = []
    @State private var resultmessage: String?

    private var filtered: [iconstateappentry] {
        let visible = apps.filter { !locallyhidden.contains($0.id) }
        guard !search.isEmpty else { return visible }
        return visible.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            Section(
                header: HeaderLabel(text: "Installed Apps", icon: "app"),
                footer: Text("System-critical bundles and apps already tracked by this tool are not listed. Hiding an app writes a safety backup first, records the bundle ID here and clears SBIconVisibility so hidden icons are not forced back onto the Home Screen.")
            ) {
                if filtered.isEmpty {
                    Text("No matching apps.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(filtered) { app in
                        Button {
                            pending = app
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.id)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "eye.slash")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Hide an App")
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .alert("Hide App?", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Hide", role: .destructive) {
                if let app = pending {
                    pending = nil
                    let result = onhide(app)
                    if result.ok {
                        locallyhidden.insert(app.id)
                    }
                    resultmessage = result.message
                }
            }
        } message: {
            Text("This clears the SBIconVisibility reveal preference and flags the app as hidden in this tool. iOS decides whether an app is truly hidden, so the icon may stay visible; a safety backup of the icon state is written first.")
        }
        .alert("Icon Toolbox", isPresented: Binding(
            get: { resultmessage != nil },
            set: { if !$0 { resultmessage = nil } }
        )) {
            Button("OK") { resultmessage = nil }
        } message: {
            Text(resultmessage ?? "")
        }
    }
}

#Preview {
    NavigationStack {
        IconStateView(mgr: laramgr.shared)
    }
}
