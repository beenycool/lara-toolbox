//
//  uiprefs.swift
//  lara
//
//  helpers for reading and writing managed preference plists under
//  /var/Managed Preferences/mobile/. every write is backed up to
//  Documents/lara_backups before it touches the plist on disk.
//

import Foundation
import Darwin
import notify

enum uiprefsdomain: String {
    case uikit = "/var/Managed Preferences/mobile/com.apple.UIKit.plist"
    case accessibility = "/var/Managed Preferences/mobile/com.apple.Accessibility.plist"
    case systemstatusui = "/var/Managed Preferences/mobile/com.apple.SystemStatusUI.plist"
    case preferences = "/var/Managed Preferences/mobile/com.apple.Preferences.plist"
}

// writes go through sbx first and fall back to vfs (see laramgr.lara_overwritefile),
// so either escape being ready is enough for the plist to be writable.
func uiprefswritable() -> Bool {
    laramgr.shared.sbxready || laramgr.shared.vfsready
}

func uiprefsbackupdir() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("lara_backups", isDirectory: true)
}

func uiprefsbackuppath(for path: String) -> URL {
    let sanitized = path.replacingOccurrences(of: "/", with: "_")
    return uiprefsbackupdir().appendingPathComponent(sanitized)
}

func uiprefsbackupexists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: uiprefsbackuppath(for: path).path)
}

// direct read works once sbx is ready, otherwise fall back to vfs.
func uiprefsreaddata(_ path: String) -> Data? {
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
        return data
    }
    let mgr = laramgr.shared
    if mgr.vfsready {
        return mgr.vfsread(path: path)
    }
    return nil
}

// copies the plist to Documents/lara_backups once, before the first write.
// an existing backup is never overwritten so the earliest known state stays
// recoverable.
@discardableResult
func uiprefsbackup(_ path: String) -> (ok: Bool, message: String) {
    let fm = FileManager.default

    guard fm.fileExists(atPath: path) else {
        return (true, "no existing plist at \(path), nothing to back up")
    }

    let backupurl = uiprefsbackuppath(for: path)
    if fm.fileExists(atPath: backupurl.path) {
        return (true, "backup already exists: \(backupurl.lastPathComponent)")
    }

    do {
        try fm.createDirectory(at: uiprefsbackupdir(), withIntermediateDirectories: true, attributes: nil)
    } catch {
        return (false, "failed to create backup folder: \(error)")
    }

    guard let data = uiprefsreaddata(path) else {
        return (false, "failed to read \(path) for backup")
    }

    do {
        try data.write(to: backupurl, options: .atomic)
        chmod(backupurl.path, 0o644)
        globallogger.log("(uiprefs) backed up \(path) to \(backupurl.path)")
        return (true, "backed up to \(backupurl.lastPathComponent)")
    } catch {
        return (false, "failed to write backup: \(error)")
    }
}

func uiprefsvalue(_ path: String, _ key: String) -> Any? {
    let result = laramgr.shared.getplistvalue(path: path, key: key)
    if result.ok {
        return result.value
    }

    guard let data = uiprefsreaddata(path),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = plist as? [String: Any] else {
        return nil
    }
    return dict[key]
}

func uiprefsbool(_ path: String, _ key: String, fallback: Bool = false) -> Bool {
    guard let number = uiprefsvalue(path, key) as? NSNumber else { return fallback }
    return number.boolValue
}

func uiprefsint(_ path: String, _ key: String, fallback: Int = 0) -> Int {
    guard let number = uiprefsvalue(path, key) as? NSNumber else { return fallback }
    return number.intValue
}

func uiprefsfloat(_ path: String, _ key: String, fallback: Float = 1.0) -> Float {
    guard let number = uiprefsvalue(path, key) as? NSNumber else { return fallback }
    return number.floatValue
}

// writes (or deletes, when value is nil) a single key through
// laramgr.setplistvalue. refuses to write when the existing plist could not
// be backed up.
@discardableResult
func uiprefswrite(_ path: String, _ key: String, _ value: Any?) -> (ok: Bool, message: String) {
    guard uiprefswritable() else {
        return (false, "Sandbox escape or VFS is not ready.")
    }

    let backup = uiprefsbackup(path)
    guard backup.ok else {
        globallogger.log("(uiprefs) write of \(key) aborted: \(backup.message)")
        return (false, "refusing to write \(key) without a backup: \(backup.message)")
    }

    let result = laramgr.shared.setplistvalue(path: path, key: (key, value), force: true)
    if result.ok {
        if value == nil {
            globallogger.log("(uiprefs) removed \(key) from \(path)")
        } else {
            globallogger.log("(uiprefs) wrote \(key) in \(path)")
        }
    } else {
        globallogger.log("(uiprefs) failed to write \(key) in \(path): \(result.message)")
    }
    return result
}

// deletes keys so the system default value comes back after a respring.
@discardableResult
func uiprefsrestore(_ path: String, keys: [String]) -> (ok: Bool, message: String) {
    guard uiprefswritable() else {
        return (false, "Sandbox escape or VFS is not ready.")
    }

    let backup = uiprefsbackup(path)
    guard backup.ok else {
        globallogger.log("(uiprefs) restore of \(path) aborted: \(backup.message)")
        return (false, "refusing to restore defaults without a backup: \(backup.message)")
    }

    guard FileManager.default.fileExists(atPath: path) else {
        return (true, "no plist at \(path), nothing to restore")
    }

    var failures: [String] = []
    for key in keys {
        let result = laramgr.shared.setplistvalue(path: path, key: (key, nil), force: true)
        if !result.ok {
            failures.append("\(key): \(result.message)")
        }
    }

    if failures.isEmpty {
        globallogger.log("(uiprefs) removed \(keys.joined(separator: ", ")) from \(path)")
        return (true, "removed \(keys.count) key(s) from \(path)")
    }

    let message = failures.joined(separator: "\n")
    globallogger.log("(uiprefs) failed to restore \(path): \(message)")
    return (false, message)
}

func uiprefspostdarkmode() {
    let name = "com.apple.darkmode.changed"
    let status = name.withCString { notify_post($0) }
    globallogger.log("(uiprefs) posted \(name) (status \(status))")
}
