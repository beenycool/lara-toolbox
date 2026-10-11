//
//  CarPlayModView.swift
//  lara
//
//  CarPlay Mod toolkit — UI layer.
//
//  Three main sections plus a backup restore section:
//   1. Wallpaper Replacement — pick a .heic/.jpg/.png and overwrite one of the
//      12 CarPlayUIServices wallpapers through the VFS overlay (size-capped).
//   2. Per-Car Capabilities — scan MobileAsset for CarPlayCapabilities.plist
//      and edit features/vehicles overrides.
//   3. App Denylist Viewer — read + clear the CarPlay*Deny*.plist files.
//
//  All file operations are gated on mgr.sbxready (data volume) or
//  mgr.vfsready (SSV wallpapers); every action logs via globallogger from
//  CarPlayModInstaller.
//

import SwiftUI
import UniformTypeIdentifiers

struct CarPlayModView: View {
    @ObservedObject var mgr: laramgr

    @State private var scan = CarPlayAssetScan()
    @State private var hasscanned = false
    @State private var scanning = false
    @State private var wallpapersizes: [String: Int64] = [:]
    @State private var backups: [CarPlayBackupEntry] = []
    @State private var pendingwallpaper: CarPlayWallpaper?
    @State private var showimporter = false
    @State private var showconfirm = false
    @State private var pending: PendingWallpaper?
    @State private var pendingimagename = ""
    @State private var busywallpaper = false
    @State private var statusline = ""

    private struct PendingWallpaper: Identifiable {
        let wallpaper: CarPlayWallpaper
        let imagePath: String

        var id: String { wallpaper.id + "|" + imagePath }
    }

    var body: some View {
        List {
            wallpaperSection
            capabilitiesSection
            denylistSection
            backupsSection

            if !statusline.isEmpty {
                Section {
                    Text(statusline)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("CarPlay Mod")
        .onAppear {
            refreshwallpapersizes()
            refreshbackups()
        }
        .onChange(of: mgr.vfsready, perform: { _ in refreshwallpapersizes() })
        .onChange(of: mgr.sbxready, perform: { ready in
            if ready && !hasscanned && !scanning {
                scanassets()
            }
        })
        .fileImporter(
            isPresented: $showimporter,
            allowedContentTypes: [UTType.heic, UTType.jpeg, UTType.png],
            allowsMultipleSelection: false,
            onCompletion: handleimport
        )
        .alert("Replace CarPlay wallpaper?", isPresented: $showconfirm, presenting: pending) { item in
            Button("Replace", role: .destructive) {
                installwallpaper(item)
            }
            Button("Cancel", role: .cancel) {
                cleanupimport(item)
            }
        } message: { item in
            Text("\(pendingimagename) will be re-encoded to HEIC and overwrite \(item.wallpaper.filename) if it fits inside the original file size. This is an in-memory (SSV) change and reverts on reboot.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var wallpaperSection: some View {
        Section {
            if !mgr.vfsready {
                Text("VFS is not ready — run the exploit and initialize VFS before replacing wallpapers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(CarPlayModInstaller.wallpapers) { wallpaper in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wallpaper.displayName)
                        Text(wallpapersubtitle(wallpaper))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("Choose") {
                        pendingwallpaper = wallpaper
                        showimporter = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(!mgr.vfsready || busywallpaper)
                }
            }

            if busywallpaper {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(statusline)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            HeaderLabel(text: "Wallpaper Replacement", icon: "photo")
        } footer: {
            Text("Overwrites CarPlayUIServices wallpapers in memory (SSV overlay). The replacement must fit inside the original file size or it is refused; the tail is zero-padded. Changes revert on reboot and may need a CarPlay reconnect to show.")
        }
    }

    @ViewBuilder
    private var capabilitiesSection: some View {
        Section {
            if !mgr.sbxready {
                Text("Sandbox escape is not ready — CarPlay assets live on the data volume and need SBX access.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button {
                scanassets()
            } label: {
                HStack {
                    Label("Scan for CarPlay assets", systemImage: "magnifyingglass")
                    Spacer()
                    if scanning {
                        ProgressView()
                    }
                }
            }
            .disabled(!mgr.sbxready || scanning)

            if hasscanned {
                if scan.capabilities.isEmpty {
                    Text("No CarPlayCapabilities.plist found under /private/var/MobileAsset.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    NavigationLink {
                        CarPlayCapabilitiesEditorView(mgr: mgr, paths: scan.capabilities, title: "All Capability Assets")
                    } label: {
                        Label("Overrides for all \(scan.capabilities.count) file(s)", systemImage: "slider.horizontal.3")
                    }

                    ForEach(scan.capabilities, id: \.self) { path in
                        NavigationLink {
                            CarPlayCapabilitiesEditorView(mgr: mgr, paths: [path], title: carplaylastcomponent(path))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(carplaylastcomponent(path))
                                Text(carplayshortpath(path))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
        } header: {
            HeaderLabel(text: "Per-Car Capabilities", icon: "car.fill")
        } footer: {
            Text("Edits the features/vehicles overrides in CarPlayCapabilities.plist. The asset daemon can restore stock files at any time (including after reboot), so reapply as needed. A backup is written to Documents/lara_backups before the first change.")
        }
    }

    @ViewBuilder
    private var denylistSection: some View {
        Section {
            if hasscanned {
                if scan.denylists.isEmpty {
                    Text("No CarPlay denylist plists found.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(scan.denylists, id: \.self) { path in
                        NavigationLink {
                            CarPlayDenylistView(mgr: mgr, path: path)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(carplaylastcomponent(path))
                                Text(carplayshortpath(path))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            } else {
                Text("Scan above to list CarPlayAppDenylist.plist, CarPlayWidgetDenyList.plist and CarPlayLiveActivitiesDenylist.plist.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            HeaderLabel(text: "App Denylist Viewer", icon: "list.bullet.rectangle")
        } footer: {
            Text("Read-only viewer with a 'clear entries' action. Stock devices usually contain only placeholder entries.")
        }
    }

    @ViewBuilder
    private var backupsSection: some View {
        Section {
            if backups.isEmpty {
                Text("No backups yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(backups) { entry in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.filename)
                            Text(carplayshortpath(entry.originalPath))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(backuplinedetail(entry))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Restore") {
                            restorebackup(entry)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canrestore(entry))
                    }
                }
            }

            Button {
                refreshbackups()
            } label: {
                Label("Refresh backups", systemImage: "arrow.clockwise")
            }
        } header: {
            HeaderLabel(text: "Restore Backup", icon: "arrow.uturn.backward")
        } footer: {
            Text("Restores the first pre-change original saved by this toolkit. SSV files are restored through VFS (VFS must be ready); data-volume files use a plain write (SBX must be ready).")
        }
    }

    // MARK: - Actions

    private func refreshwallpapersizes() {
        guard mgr.vfsready else {
            wallpapersizes = [:]
            return
        }
        var sizes: [String: Int64] = [:]
        for wallpaper in CarPlayModInstaller.wallpapers {
            sizes[wallpaper.id] = mgr.vfssize(path: wallpaper.path)
        }
        wallpapersizes = sizes
    }

    private func refreshbackups() {
        backups = CarPlayModInstaller.shared.listBackups()
    }

    private func scanassets() {
        guard mgr.sbxready, !scanning else { return }
        scanning = true
        statusline = "scanning MobileAsset..."

        DispatchQueue.global(qos: .userInitiated).async {
            let result = CarPlayModInstaller.shared.scanAssets()
            DispatchQueue.main.async {
                scan = result
                hasscanned = true
                scanning = false
                statusline = "found \(result.capabilities.count) capability plist(s), \(result.denylists.count) denylist plist(s)"
            }
        }
    }

    private func handleimport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let wallpaper = pendingwallpaper else { return }
            let name = url.lastPathComponent
            if let imported = CarPlayModInstaller.shared.importWallpaperImage(from: url) {
                pending = PendingWallpaper(wallpaper: wallpaper, imagePath: imported)
                pendingimagename = name
                showconfirm = true
            } else {
                statusline = "image import failed"
            }
        case .failure(let error):
            statusline = "image import failed: \(error.localizedDescription)"
        }
    }

    private func installwallpaper(_ item: PendingWallpaper) {
        guard mgr.vfsready else {
            statusline = "vfs not ready"
            return
        }
        busywallpaper = true
        statusline = "preparing \(item.wallpaper.displayName)..."

        DispatchQueue.global(qos: .userInitiated).async {
            let result = CarPlayModInstaller.shared.installWallpaper(item.wallpaper, imagePath: item.imagePath)
            DispatchQueue.main.async {
                busywallpaper = false
                statusline = result.ok ? result.message : "failed: \(result.message)"
                try? FileManager.default.removeItem(atPath: item.imagePath)
                refreshbackups()
            }
        }
    }

    private func cleanupimport(_ item: PendingWallpaper) {
        try? FileManager.default.removeItem(atPath: item.imagePath)
    }

    private func canrestore(_ entry: CarPlayBackupEntry) -> Bool {
        entry.isSystemFile ? mgr.vfsready : mgr.sbxready
    }

    private func restorebackup(_ entry: CarPlayBackupEntry) {
        guard canrestore(entry) else {
            statusline = entry.isSystemFile ? "vfs not ready" : "sandbox escape not ready"
            return
        }
        statusline = "restoring \(entry.filename)..."

        DispatchQueue.global(qos: .userInitiated).async {
            let result = CarPlayModInstaller.shared.restoreBackup(entry)
            DispatchQueue.main.async {
                statusline = result.ok ? "restored \(entry.filename)" : "restore failed: \(result.message)"
                refreshwallpapersizes()
                refreshbackups()
            }
        }
    }

    private func wallpapersubtitle(_ wallpaper: CarPlayWallpaper) -> String {
        var parts: [String] = [wallpaper.filename]
        if let size = wallpapersizes[wallpaper.id], size > 0 {
            parts.append(CarPlayModInstaller.byteString(Int(size)))
        }
        if backups.contains(where: { $0.originalPath == wallpaper.path }) {
            parts.append("modified (backup saved)")
        }
        return parts.joined(separator: " • ")
    }

    private func backuplinedetail(_ entry: CarPlayBackupEntry) -> String {
        var parts: [String] = []
        if entry.size > 0 {
            parts.append(CarPlayModInstaller.byteString(Int(entry.size)))
        }
        if let created = entry.createdAt {
            parts.append(carplaybackupformatter.string(from: created))
        }
        parts.append(entry.isSystemFile ? "SSV" : "Data volume")
        return parts.joined(separator: " • ")
    }
}

// MARK: - Capability editor

struct CarPlayCapabilitiesEditorView: View {
    @ObservedObject var mgr: laramgr
    let paths: [String]
    let title: String

    @State private var squarecorners = false
    @State private var interfacestyle: CarPlayInterfaceStyle = .unchanged
    @State private var flipmode: CarPlayFlipMode = .unchanged
    @State private var viewareainsets = ""
    @State private var snapshot = CarPlayCapabilitySnapshot()
    @State private var anybackup = false
    @State private var busy = false
    @State private var message = ""
    @State private var showapply = false
    @State private var showrestore = false

    private var isnoop: Bool {
        !squarecorners &&
        interfacestyle == .unchanged &&
        flipmode == .unchanged &&
        viewareainsets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if paths.count == 1 {
                Section {
                    if snapshot.featureValues.isEmpty {
                        Text("No features dictionary found (or the asset is not readable yet).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(snapshot.featureValues.keys.sorted(), id: \.self) { key in
                            HStack {
                                Text(key)
                                    .font(.caption)
                                Spacer()
                                Text(snapshot.featureValues[key] ?? "")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                } header: {
                    Text("Current values")
                }

                Section {
                    Text(carplayshortpath(paths[0]))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if snapshot.hasVehicles {
                        Text("\(snapshot.vehicleOverrideCount) vehicle entry(ies) declare one of the overridable keys.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Section {
                    Text("Applying to \(paths.count) CarPlayCapabilities.plist file(s).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Toggle("Dashboard corners: square", isOn: $squarecorners)
                Picker("User interface style", selection: $interfacestyle) {
                    ForEach(CarPlayInterfaceStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Picker("Right-hand drive flip", selection: $flipmode) {
                    ForEach(CarPlayFlipMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("viewAreaInsets (custom string)")
                    TextField("{{0, 0}, {0, 0}}", text: $viewareainsets)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            } header: {
                Text("Overrides")
            } footer: {
                Text("Written into the asset's features dictionary, plus the per-vehicle features entries that already define the same key. Leave fields untouched to keep stock values. Empty viewAreaInsets means unchanged. Square corners sets dashboardRoundedCorners to {{0, 0}, {0, 0}}.")
            }

            Section {
                Button {
                    showapply = true
                } label: {
                    HStack {
                        Label("Apply Overrides", systemImage: "checkmark.circle")
                        Spacer()
                        if busy {
                            ProgressView()
                        }
                    }
                }
                .disabled(!mgr.sbxready || busy || isnoop)

                Button(role: .destructive) {
                    showrestore = true
                } label: {
                    Label("Restore Originals", systemImage: "arrow.uturn.backward")
                }
                .disabled(!mgr.sbxready || busy || !anybackup)
                .alert("Restore originals?", isPresented: $showrestore) {
                    Button("Restore", role: .destructive) {
                        restoreoriginals()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Restores the first pre-change backup for each file in this list.")
                }
            } footer: {
                Text("The system asset daemon may restore stock files; reapply as needed. Backups live in Documents/lara_backups.")
            }

            if !message.isEmpty {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .onAppear(perform: loadsnapshot)
        .alert("Apply CarPlay overrides?", isPresented: $showapply) {
            Button("Apply") {
                applyoverrides()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup is written before the first change. Reconnect CarPlay (or respring) to see the result.")
        }
    }

    private func loadsnapshot() {
        let allbackups = CarPlayModInstaller.shared.listBackups()
        anybackup = paths.contains { path in
            allbackups.contains { $0.originalPath == path }
        }

        guard let first = paths.first else {
            snapshot = CarPlayCapabilitySnapshot()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = CarPlayModInstaller.shared.inspectCapabilities(path: first)
            DispatchQueue.main.async {
                snapshot = result
            }
        }
    }

    private func applyoverrides() {
        guard mgr.sbxready else {
            message = "sandbox escape not ready"
            return
        }

        busy = true
        message = "applying..."

        let overrides = CarPlayCapabilityOverrides(
            squareDashboardCorners: squarecorners,
            userInterfaceStyle: interfacestyle,
            rightHandDriveFlip: flipmode,
            viewAreaInsets: viewareainsets.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let targets = paths

        DispatchQueue.global(qos: .userInitiated).async {
            var applied = 0
            var failed = 0
            for path in targets {
                let result = CarPlayModInstaller.shared.applyCapabilityOverrides(path: path, overrides: overrides)
                if result.ok {
                    applied += 1
                } else {
                    failed += 1
                }
            }
            DispatchQueue.main.async {
                busy = false
                message = failed == 0
                    ? "applied overrides to \(applied) file(s)"
                    : "applied to \(applied) file(s), failed \(failed) — see logs"
                loadsnapshot()
            }
        }
    }

    private func restoreoriginals() {
        busy = true

        let targets = paths
        DispatchQueue.global(qos: .userInitiated).async {
            var restored = 0
            var failed = 0
            for path in targets {
                guard let entry = CarPlayModInstaller.shared.backupEntry(forOriginalPath: path) else { continue }
                let result = CarPlayModInstaller.shared.restoreBackup(entry)
                if result.ok {
                    restored += 1
                } else {
                    failed += 1
                }
            }
            DispatchQueue.main.async {
                busy = false
                message = failed == 0
                    ? "restored \(restored) file(s)"
                    : "restored \(restored) file(s), failed \(failed) — see logs"
                loadsnapshot()
            }
        }
    }
}

// MARK: - Denylist viewer

struct CarPlayDenylistView: View {
    @ObservedObject var mgr: laramgr
    let path: String

    @State private var contents = CarPlayDenylistContents()
    @State private var showclear = false
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        List {
            Section {
                if contents.entries.isEmpty {
                    Text("No entries")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(contents.entries, id: \.self) { entry in
                        Text(entry)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            } header: {
                Text("Entries — \(contents.rootKind)")
            } footer: {
                Text(carplayshortpath(path))
            }

            Section {
                Button(role: .destructive) {
                    showclear = true
                } label: {
                    HStack {
                        Label("Clear Entries", systemImage: "trash")
                        Spacer()
                        if busy {
                            ProgressView()
                        }
                    }
                }
                .disabled(!mgr.sbxready || busy || !contents.clearable)
            } footer: {
                Text("A backup is written to Documents/lara_backups before the file is replaced with an empty container. Stock devices usually contain only placeholder entries, so clearing may not change behaviour.")
            }

            if !message.isEmpty {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(carplaylastcomponent(path))
        .onAppear(perform: load)
        .alert("Clear denylist entries?", isPresented: $showclear) {
            Button("Clear", role: .destructive) {
                clearentries()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces every entry in \(carplaylastcomponent(path)) with an empty container. A backup is saved automatically.")
        }
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = CarPlayModInstaller.shared.readDenylist(path: path)
            DispatchQueue.main.async {
                contents = loaded
            }
        }
    }

    private func clearentries() {
        guard mgr.sbxready else {
            message = "sandbox escape not ready"
            return
        }

        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CarPlayModInstaller.shared.clearDenylist(path: path)
            DispatchQueue.main.async {
                busy = false
                message = result.ok ? result.message : "failed: \(result.message)"
                load()
            }
        }
    }
}

// MARK: - Shared helpers

private func carplaylastcomponent(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

private func carplayshortpath(_ path: String) -> String {
    path.replacingOccurrences(of: "/private/var/MobileAsset/", with: "")
}

private let carplaybackupformatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()
