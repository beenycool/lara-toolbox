//
//  SoundsAndDisplayView.swift
//  lara
//
//  Lab: custom system sounds pack + Night Shift boost.
//  Both features write through lara's overwrite primitives, so they are
//  in-memory only and revert on reboot.
//

import SwiftUI
import Foundation
import UniformTypeIdentifiers

// MARK: - Sound targets

struct labsoundtarget: Identifiable, Hashable {
    let name: String
    let path: String

    var id: String { path }

    var filename: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// Same UISounds paths dirtyZero lists for its "Sound Effects" section
// (views/tweaks/dirtyZero/dirtyZeroTweakArray.swift).
private let labsoundtargets: [labsoundtarget] = [
    labsoundtarget(name: "AirDrop Invite", path: "/System/Library/Audio/UISounds/Modern/airdrop_invite.cat"),
    labsoundtarget(name: "Charger Connected", path: "/System/Library/Audio/UISounds/connect_power.caf"),
    labsoundtarget(name: "Low Battery", path: "/System/Library/Audio/UISounds/low_power.caf"),
    labsoundtarget(name: "Apple Pay Success", path: "/System/Library/Audio/UISounds/payment_success.caf"),
    labsoundtarget(name: "Apple Pay Failure", path: "/System/Library/Audio/UISounds/payment_failure.caf"),
    labsoundtarget(name: "Keypad 0", path: "/System/Library/Audio/UISounds/nano/dtmf-0.caf"),
    labsoundtarget(name: "Keypad 1", path: "/System/Library/Audio/UISounds/nano/dtmf-1.caf"),
    labsoundtarget(name: "Keypad 2", path: "/System/Library/Audio/UISounds/nano/dtmf-2.caf"),
    labsoundtarget(name: "Keypad 3", path: "/System/Library/Audio/UISounds/nano/dtmf-3.caf"),
    labsoundtarget(name: "Keypad 4", path: "/System/Library/Audio/UISounds/nano/dtmf-4.caf"),
    labsoundtarget(name: "Keypad 5", path: "/System/Library/Audio/UISounds/nano/dtmf-5.caf"),
    labsoundtarget(name: "Keypad 6", path: "/System/Library/Audio/UISounds/nano/dtmf-6.caf"),
    labsoundtarget(name: "Keypad 7", path: "/System/Library/Audio/UISounds/nano/dtmf-7.caf"),
    labsoundtarget(name: "Keypad 8", path: "/System/Library/Audio/UISounds/nano/dtmf-8.caf"),
    labsoundtarget(name: "Keypad 9", path: "/System/Library/Audio/UISounds/nano/dtmf-9.caf"),
    labsoundtarget(name: "Keypad Star", path: "/System/Library/Audio/UISounds/nano/dtmf-star.caf"),
    labsoundtarget(name: "Keypad Pound", path: "/System/Library/Audio/UISounds/nano/dtmf-pound.caf"),
]

// MARK: - Night Shift

private let nightshiftpath = "/var/Managed Preferences/mobile/com.apple.CoreBrightness.plist"
private let nskeyenabled = "BlueLightReductionEnabled"
private let nskeycct = "BlueLightReductionCCTTargetRaw"
private let nskeyfactor = "BlueLightReductionFactorValue"
private let nskeymode = "BlueLightReductionMode"

private let nscctmin: Double = 2700
private let nscctmax: Double = 6500
private let nscctdefault: Double = 3400
private let nsstrengthdefault: Double = 70

private func labsoundsize(_ path: String, mgr: laramgr) -> Int64? {
    if mgr.vfsready {
        let size = mgr.vfssize(path: path)
        if size > 0 { return size }
    }

    if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
       let number = attributes[.size] as? NSNumber,
       number.int64Value > 0 {
        return number.int64Value
    }

    return nil
}

private var labsoundtypes: [UTType] {
    var types: [UTType] = []
    if let caf = UTType(filenameExtension: "caf") { types.append(caf) }
    if let aiff = UTType(filenameExtension: "aiff") { types.append(aiff) }
    return types.isEmpty ? [.audio] : types
}

private func labsoundbytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - View

struct SoundsAndDisplayView: View {
    @ObservedObject var mgr: laramgr

    // sounds
    @State private var selectedsound: labsoundtarget? = labsoundtargets.first
    @State private var soundsizes: [String: Int64] = [:]
    @State private var showimporter = false
    @State private var importedpath: String?
    @State private var importedname: String?
    @State private var importedsize: Int64?
    @State private var isreplacing = false
    @State private var soundstatus: String?

    // night shift
    @State private var nsenabled = false
    @State private var nscct = nscctdefault
    @State private var nsstrength = nsstrengthdefault
    @State private var nsstatus: String?
    @State private var nsbusy = false
    @State private var showresetconfirm = false

    var body: some View {
        List {
            soundssection
            replacementsection
            nightshiftsection
            statussection
        }
        .navigationTitle("Sounds & Display")
        .onAppear {
            loadsoundsizes()
            loadnightshift()
        }
        .onChange(of: mgr.vfsready) { _ in
            loadsoundsizes()
        }
        .onChange(of: mgr.sbxready) { _ in
            loadnightshift()
        }
        .fileImporter(
            isPresented: $showimporter,
            allowedContentTypes: labsoundtypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importsound(url) }
            case .failure(let error):
                mgr.logmsg("(sounds) import failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: sounds

    private var soundssection: some View {
        Section {
            ForEach(labsoundtargets) { target in
                Button {
                    selectedsound = target
                    soundstatus = nil
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.name)
                                .foregroundColor(.primary)
                            Text(target.path)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Text(soundsizes[target.path].map { labsoundbytes($0) } ?? "—")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)

                        if selectedsound == target {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            HeaderLabel(text: "Custom System Sounds", icon: "speaker.wave.2")
        } footer: {
            Text("Targets are the same UISounds files dirtyZero lists under Sound Effects. Sizes are read through VFS when it is initialized.")
        }
    }

    private var replacementsection: some View {
        Section {
            HStack {
                Text("Selected")
                Spacer()
                Text(selectedsound?.name ?? "None")
                    .foregroundColor(.secondary)
            }

            Button {
                showimporter = true
            } label: {
                HStack {
                    Text("Choose Replacement File")
                    Spacer()
                    Text(importedname ?? "None")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let importedsize {
                HStack {
                    Text("Replacement Size")
                    Spacer()
                    Text(labsoundbytes(importedsize))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            if let target = selectedsound, let targetsize = soundsizes[target.path] {
                HStack {
                    Text("Original Size")
                    Spacer()
                    Text(labsoundbytes(targetsize))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            if let target = selectedsound,
               let targetsize = soundsizes[target.path],
               let importedsize,
               importedsize > targetsize {
                Text("Too large: \(labsoundbytes(importedsize)) > \(labsoundbytes(targetsize)). The overwrite cannot grow the file, so a smaller file is required.")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button(isreplacing ? "Replacing..." : "Replace Sound") {
                replacesound()
            }
            .disabled(!canreplacesound)

            Button {
                backupsound()
            } label: {
                Text("Back Up Original Sound")
            }
            .disabled(!mgr.vfsready || selectedsound == nil)

            Button {
                loadsoundsizes()
            } label: {
                Text("Refresh Sizes")
            }
            .disabled(!mgr.vfsready)

            if let soundstatus {
                Text(soundstatus)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } header: {
            HeaderLabel(text: "Replacement", icon: "arrow.triangle.2.circlepath")
        } footer: {
            Text("The replacement must be no larger than the original sound: the overwrite cannot grow a file, and the leftover tail is zeroed. Larger files are refused, so convert to a smaller .caf/.aiff first. \"Back Up Original Sound\" saves the current bytes to Documents/UISoundsBackup so the original can be re-imported later. Changes live in memory (SSV) and revert on reboot. Respring for the new sound to take effect.")
        }
    }

    private var canreplacesound: Bool {
        mgr.vfsready && !isreplacing && selectedsound != nil && importedpath != nil
    }

    private func loadsoundsizes() {
        let targets = labsoundtargets
        let mgrobject = mgr
        DispatchQueue.global(qos: .userInitiated).async {
            var sizes: [String: Int64] = [:]
            for target in targets {
                if let size = labsoundsize(target.path, mgr: mgrobject) {
                    sizes[target.path] = size
                }
            }
            DispatchQueue.main.async {
                soundsizes = sizes
                mgrobject.logmsg("(sounds) read sizes for \(sizes.count)/\(targets.count) targets")
            }
        }
    }

    private func importsound(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard ["caf", "aiff", "aif"].contains(ext) else {
            soundstatus = "Unsupported file type .\(ext). Import a .caf or .aiff file."
            mgr.logmsg("(sounds) rejected import with extension .\(ext)")
            return
        }

        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LabSounds")
        let dest = dir.appendingPathComponent(url.lastPathComponent)

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: url, to: dest)

            let attributes = try fm.attributesOfItem(atPath: dest.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                try? fm.removeItem(at: dest)
                soundstatus = "The selected file is empty."
                mgr.logmsg("(sounds) rejected empty import \(url.lastPathComponent)")
                return
            }

            importedpath = dest.path
            importedname = url.lastPathComponent
            importedsize = size
            soundstatus = nil
            mgr.logmsg("(sounds) imported \(url.lastPathComponent) (\(size) bytes)")
        } catch {
            soundstatus = "Import failed: \(error.localizedDescription)"
            mgr.logmsg("(sounds) import failed: \(error.localizedDescription)")
        }
    }

    private func replacesound() {
        guard !isreplacing else { return }

        guard mgr.vfsready else {
            soundstatus = "VFS is not ready. Initialize the exploit and VFS first."
            mgr.logmsg("(sounds) replace aborted: vfs not ready")
            return
        }

        guard let target = selectedsound else {
            soundstatus = "Select a target sound first."
            return
        }

        guard let srcpath = importedpath, let srcname = importedname else {
            soundstatus = "Choose a replacement .caf/.aiff file first."
            return
        }

        guard FileManager.default.fileExists(atPath: srcpath) else {
            soundstatus = "The imported file is gone. Choose it again."
            mgr.logmsg("(sounds) replacement file missing: \(srcpath)")
            return
        }

        guard let srcsize = importedsize, srcsize > 0 else {
            soundstatus = "Could not read the replacement file size."
            return
        }

        guard let targetsize = labsoundsize(target.path, mgr: mgr), targetsize > 0 else {
            soundstatus = "Could not read the original size of \(target.name). Re-initialize VFS and try again."
            mgr.logmsg("(sounds) could not read size of \(target.path)")
            return
        }

        guard srcsize <= targetsize else {
            soundstatus = "Refused: \(labsoundbytes(srcsize)) replacement is larger than the original \(labsoundbytes(targetsize)). Use a smaller .caf/.aiff."
            mgr.logmsg("(sounds) refused \(srcname) for \(target.name): \(srcsize) > \(targetsize) bytes")
            Alertinator.shared.alert(
                title: "Replacement Too Large",
                body: "\(srcname) is \(labsoundbytes(srcsize)), but \(target.name) is only \(labsoundbytes(targetsize)).\n\nThe overwrite cannot grow the file and the tail is zeroed, so the replacement bytes must be <= the original size. Convert the sound to a smaller .caf (shorter or lower sample rate) and try again."
            )
            return
        }

        isreplacing = true
        soundstatus = nil

        let targetpath = target.path
        let targetname = target.name
        let mgrobject = mgr
        mgrobject.logmsg("(sounds) replacing \(targetname) with \(srcname) (\(srcsize)/\(targetsize) bytes)")

        DispatchQueue.global(qos: .userInitiated).async {
            let ok = mgrobject.vfsoverwritefromlocalpath(target: targetpath, source: srcpath)
            DispatchQueue.main.async {
                isreplacing = false
                if ok {
                    soundstatus = "Replaced \(targetname). Respring for it to take effect; it reverts on reboot."
                    mgrobject.logmsg("(sounds) replaced \(targetname)")
                } else {
                    soundstatus = "Overwrite failed for \(targetname). Check the log."
                    mgrobject.logmsg("(sounds) overwrite failed for \(targetpath)")
                }
            }
        }
    }

    private func backupsound() {
        guard mgr.vfsready else {
            soundstatus = "VFS is not ready. Initialize VFS before backing up."
            return
        }

        guard let target = selectedsound else {
            soundstatus = "Select a target sound first."
            return
        }

        guard let data = mgr.vfsread(path: target.path, maxSize: 8 * 1024 * 1024) else {
            soundstatus = "Could not read \(target.name) through VFS."
            mgr.logmsg("(sounds) backup failed to read \(target.path)")
            return
        }

        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UISoundsBackup")
        let dest = dir.appendingPathComponent(target.filename)

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try data.write(to: dest)
            soundstatus = "Backed up \(target.filename) (\(data.count) bytes) to Documents/UISoundsBackup."
            mgr.logmsg("(sounds) backed up \(target.path) -> \(dest.path)")
        } catch {
            soundstatus = "Backup failed: \(error.localizedDescription)"
            mgr.logmsg("(sounds) backup failed: \(error.localizedDescription)")
        }
    }

    // MARK: night shift

    private var nightshiftsection: some View {
        Section {
            HStack {
                Image(systemName: "flask")
                Text("Experimental")
                    .font(.caption)
                    .bold()
                Spacer()
            }
            .foregroundColor(.orange)

            Toggle("Enable Night Shift", isOn: $nsenabled)

            HStack {
                Text("Color Temperature")
                Spacer()
                Text("\(Int(nscct)) K")
                    .foregroundColor(.secondary)
                    .monospaced()
            }
            Slider(value: $nscct, in: nscctmin...nscctmax, step: 50) {
                Text("Color Temperature")
            } minimumValueLabel: {
                Text("\(Int(nscctmin))K").font(.caption2)
            } maximumValueLabel: {
                Text("\(Int(nscctmax))K").font(.caption2)
            }
            .disabled(!nsenabled)

            HStack {
                Text("Strength")
                Spacer()
                Text("\(Int(nsstrength))%")
                    .foregroundColor(.secondary)
                    .monospaced()
            }
            Slider(value: $nsstrength, in: 0...100, step: 1)
                .disabled(!nsenabled)

            Button(nsbusy ? "Applying..." : "Apply Night Shift") {
                applynightshift()
            }
            .disabled(nsbusy || !mgr.sbxready)

            Button(role: .destructive) {
                showresetconfirm = true
            } label: {
                Text("Reset to Stock")
            }
            .disabled(nsbusy || !mgr.sbxready)
            .alert("Reset Night Shift to stock?", isPresented: $showresetconfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) { resetnightshift() }
            } message: {
                Text("Removes the BlueLightReduction* keys from com.apple.CoreBrightness.plist after backing the file up. Respring or reboot so CoreBrightness falls back to stock.")
            }

            if let nsstatus {
                Text(nsstatus)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } header: {
            HeaderLabel(text: "Night Shift Boost (Experimental)", icon: "moon.fill")
        } footer: {
            Text("Writes BlueLightReductionEnabled, BlueLightReductionCCTTargetRaw, BlueLightReductionFactorValue and BlueLightReductionMode to /var/Managed Preferences/mobile/com.apple.CoreBrightness.plist, then resprings so CoreBrightness reloads it. If nothing changes, reboot. The value of Mode is written as 1; its exact meaning is unconfirmed. Reset to Stock removes the keys instead of restoring previous values.")
        }
    }

    private func loadnightshift() {
        guard mgr.sbxready else {
            nsstatus = "Sandbox escape is not ready; Night Shift state was not loaded."
            return
        }

        nsbusy = true
        defer { nsbusy = false }

        let enabledresult = mgr.getplistvalue(path: nightshiftpath, key: nskeyenabled)
        if enabledresult.ok, let number = enabledresult.value as? NSNumber {
            nsenabled = number.boolValue
        }

        let cctresult = mgr.getplistvalue(path: nightshiftpath, key: nskeycct)
        if cctresult.ok, let number = cctresult.value as? NSNumber {
            nscct = min(max(number.doubleValue, nscctmin), nscctmax)
        }

        let factorresult = mgr.getplistvalue(path: nightshiftpath, key: nskeyfactor)
        if factorresult.ok, let number = factorresult.value as? NSNumber {
            let raw = number.doubleValue
            let percent = raw <= 1.0 ? raw * 100.0 : raw
            nsstrength = min(max(percent, 0), 100)
        }

        mgr.logmsg("(nightshift) loaded state enabled=\(nsenabled) cct=\(Int(nscct)) strength=\(Int(nsstrength))%")
    }

    private func applynightshift() {
        guard mgr.sbxready else {
            nsstatus = "Sandbox escape is not ready. Run the exploit first."
            mgr.logmsg("(nightshift) apply aborted: sbx not ready")
            return
        }

        guard FileManager.default.fileExists(atPath: nightshiftpath) else {
            nsstatus = "com.apple.CoreBrightness.plist was not found. Nothing was written."
            mgr.logmsg("(nightshift) plist not found at \(nightshiftpath)")
            return
        }

        nsbusy = true
        defer { nsbusy = false }

        let backup = uiprefsbackup(nightshiftpath)
        guard backup.ok else {
            nsstatus = "Backup failed; nothing was written. \(backup.message)"
            mgr.logmsg("(nightshift) apply aborted: backup failed - \(backup.message)")
            return
        }
        mgr.logmsg("(nightshift) backup: \(backup.message)")

        let modevalue: Int? = nsenabled ? 1 : nil
        let writes: [(String, Any?)] = [
            (nskeyenabled, nsenabled),
            (nskeycct, Int(nscct)),
            (nskeyfactor, nsstrength / 100.0),
            (nskeymode, modevalue),
        ]

        var failures: [String] = []
        for (key, value) in writes {
            let result = mgr.setplistvalue(path: nightshiftpath, key: (key, value), force: true)
            let shown = value.map { String(describing: $0) } ?? "<removed>"
            if result.ok {
                mgr.logmsg("(nightshift) set \(key) = \(shown)")
            } else {
                failures.append("\(key): \(result.message)")
                mgr.logmsg("(nightshift) failed \(key): \(result.message)")
            }
        }

        if failures.isEmpty {
            nsstatus = "Applied. Respring to reload CoreBrightness."
            Alertinator.shared.alert(
                title: "Night Shift Applied",
                body: "Wrote \(writes.count) keys to com.apple.CoreBrightness.plist.\n\nRespring to reload them. If Night Shift still does not change, a reboot is the only full reload.",
                actionLabel: "Respring",
                action: { mgr.respring() }
            )
        } else {
            nsstatus = failures.joined(separator: "\n")
            Alertinator.shared.alert(
                title: "Night Shift Apply Failed",
                body: failures.joined(separator: "\n")
            )
        }
    }

    private func resetnightshift() {
        guard mgr.sbxready else {
            nsstatus = "Sandbox escape is not ready. Run the exploit first."
            mgr.logmsg("(nightshift) reset aborted: sbx not ready")
            return
        }

        guard FileManager.default.fileExists(atPath: nightshiftpath) else {
            nsstatus = "com.apple.CoreBrightness.plist was not found; nothing to reset."
            mgr.logmsg("(nightshift) plist not found at \(nightshiftpath), reset skipped")
            return
        }

        nsbusy = true
        defer { nsbusy = false }

        let backup = uiprefsbackup(nightshiftpath)
        guard backup.ok else {
            nsstatus = "Backup failed; nothing was removed. \(backup.message)"
            mgr.logmsg("(nightshift) reset aborted: backup failed - \(backup.message)")
            return
        }
        mgr.logmsg("(nightshift) backup: \(backup.message)")

        var failures: [String] = []
        for key in [nskeyenabled, nskeycct, nskeyfactor, nskeymode] {
            let result = mgr.setplistvalue(path: nightshiftpath, key: (key, nil), force: true)
            if result.ok {
                mgr.logmsg("(nightshift) removed \(key)")
            } else {
                failures.append("\(key): \(result.message)")
                mgr.logmsg("(nightshift) failed to remove \(key): \(result.message)")
            }
        }

        if failures.isEmpty {
            nsenabled = false
            nsstatus = "Keys removed. Respring (or reboot) so CoreBrightness falls back to stock."
            Alertinator.shared.alert(
                title: "Night Shift Reset",
                body: "Removed the BlueLightReduction* keys. Respring or reboot for CoreBrightness to fall back to stock Night Shift behavior.",
                actionLabel: "Respring",
                action: { mgr.respring() }
            )
        } else {
            nsstatus = failures.joined(separator: "\n")
            Alertinator.shared.alert(
                title: "Night Shift Reset Failed",
                body: failures.joined(separator: "\n")
            )
        }
    }

    // MARK: status

    private var statussection: some View {
        Section {
            Text(globallogger.logs.last ?? "No logs yet")
                .font(.system(size: 13, design: .monospaced))

            Button("Respring") {
                mgr.respring()
            }
        } header: {
            HeaderLabel(text: "Status", icon: "terminal")
        }
    }
}

#Preview {
    NavigationStack {
        SoundsAndDisplayView(mgr: laramgr.shared)
    }
}
