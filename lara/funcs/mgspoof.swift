//
//  mgspoof.swift
//  lara
//
//  MobileGestalt version-spoof helpers for the "Device & Status Spoofer"
//  screen (views/tweaks/spoofer/StatusBarFakesView.swift).
//
//  The MobileGestalt cache at mgCurrentPath is a binary plist whose CacheExtra
//  dictionary is keyed by obfuscated ("symbolic") key names; the readable names
//  (BuildVersion, ProductVersion, ...) only exist as strings inside
//  libMobileGestalt.dylib. This file carries the deobfuscation table so the
//  symbolic slots can be found without touching the binary.
//
//  Key table source: PoomSmart/MGKeys `mapping-gestalt.h` and The Apple Wiki
//  "List of MobileGestalt keys" (obfuscated key <-> readable key). All entries
//  used here are listed as current there (iOS 7.0+ / iOS 11.0+, never removed)
//  and the readable strings were verified in iOS 26.0 libMobileGestalt.dylib
//  by the reverse-engineering pass behind this feature. The symbolic side is
//  still treated as best-effort: mgspooffindkey() double-checks the cache and
//  mgspoofreadvalues() reports unmappable keys so the UI can fall back to a
//  read-only mode.
//
//  Reuses existing globals (nothing existing is modified):
//    - mgCurrentPath                       (views/tweaks/mobilegestalt/GestaltView.swift)
//    - loadMutablePlistDictionary(from:)   (GestaltView.swift, pure plist loader)
//    - laramgr.shared.vfsread / vfsready / lara_overwritefile / logmsg
//
//  GestaltView's verifyPlist() is intentionally NOT used here: it can pop an
//  Alertinator alert, and these helpers run on a background queue. mgspoof
//  carries its own quiet serialization validation instead.
//
//  All writes go through laramgr.lara_overwritefile(target:data:fallback_vfs:)
//  with fallback_vfs: false, exactly like GestaltView.applyGestalt(), so MG
//  writes require mgr.sbxready (sandbox escape).
//

import Foundation
import Darwin

// MARK: - Readable <-> symbolic key table

/// Readable MobileGestalt key -> obfuscated CacheExtra key.
let mgspoofkeymap: [String: String] = [
    "BuildVersion":   "mZfUC7qo4pURNhyMHZ62RQ",
    "ProductVersion": "qNNddlUK+B/YlooNoymwgA",
    "BuildID":        "qwXfFvH5jPXPxrny0XuGtQ",
    "ReleaseType":    "9UCjT7Qfi4xLVvPAKIzTCQ",
    "DeviceClass":    "+3Uf0Pm5F8Xy7Onyvko0vA",
    "ProductType":    "h9jDsbgj7xIVeIQ8S3/X3Q",
]

/// Readable aliases that libMobileGestalt resolves to another readable key.
/// "OSVersion" has no separate symbolic slot on modern iOS: MGCopyAnswer
/// answers it from ProductVersion, so both share one CacheExtra entry. This is
/// also why OSVersion is read-only here and never written on its own.
let mgspoofaliases: [String: String] = [
    "OSVersion": "ProductVersion",
]

/// Keys the UI displays.
let mgspoofreadkeys = [
    "BuildVersion", "ProductVersion", "OSVersion",
    "BuildID", "ReleaseType", "DeviceClass", "ProductType",
]

/// Keys the UI is allowed to write. OSVersion is deliberately absent (alias).
let mgspoofwritekeys = ["BuildVersion", "ProductVersion"]

func mgspoofcanonicalkey(_ key: String) -> String {
    return mgspoofaliases[key] ?? key
}

/// Finds the CacheExtra slot for a readable key: the literal readable key
/// first (some caches/tools store plain names), then the deobfuscation table.
/// Returns nil when no slot can be mapped; the UI treats that as "read-only"
/// for the affected key.
func mgspooffindkey(_ readable: String, in cacheExtra: NSDictionary) -> String? {
    if cacheExtra[readable] != nil {
        return readable
    }
    let canonical = mgspoofcanonicalkey(readable)
    return mgspoofkeymap[canonical]
}

// MARK: - Cache loading / reading

struct mgspoofvalues {
    var ok: Bool = false
    var message: String = ""
    var values: [String: String] = [:]
    var unmapped: [String] = []
    var present: [String] = []
}

/// Reads the MobileGestalt cache binary plist. A direct read works once the
/// sandbox escape is active; otherwise the VFS read path is used.
func mgspoofreadcache() -> NSMutableDictionary? {
    let url = URL(fileURLWithPath: mgCurrentPath)
    if let dict = try? loadMutablePlistDictionary(from: url) {
        return dict
    }

    let mgr = laramgr.shared
    guard mgr.vfsready,
          let data = mgr.vfsread(path: mgCurrentPath, maxSize: 8 * 1024 * 1024) else {
        return nil
    }
    guard let plist = try? PropertyListSerialization.propertyList(
        from: data,
        options: [.mutableContainersAndLeaves],
        format: nil
    ) else {
        return nil
    }
    return plist as? NSMutableDictionary
}

/// Raw bytes of a file, direct read first and VFS as fallback. Used by the
/// safety backup so it also works on builds where only VFS is available.
func mgspoofreaddata(path: String, maxSize: Int = 8 * 1024 * 1024) -> Data? {
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
        return data
    }
    let mgr = laramgr.shared
    if mgr.vfsready {
        return mgr.vfsread(path: path, maxSize: maxSize)
    }
    return nil
}

/// Some caches also serialize the values into the CacheData blob; parse it
/// when it happens to be a plist. Best-effort, read-only.
func mgspoofparsecachedata(_ dict: NSDictionary) -> NSDictionary? {
    guard let data = dict["CacheData"] as? Data else { return nil }
    guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
        return nil
    }
    return plist as? NSDictionary
}

func mgspoofstring(from value: Any) -> String {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return "\(value)"
}

/// Best-effort read of one readable key: CacheExtra (literal, alias or
/// symbolic slot) first, then the parsed CacheData blob. Never used for
/// writes; writes always target a CacheExtra slot from mgspooffindkey().
func mgspooffindvalue(_ readable: String, in dict: NSDictionary) -> Any? {
    if let cacheExtra = dict["CacheExtra"] as? NSDictionary,
       let slot = mgspooffindkey(readable, in: cacheExtra),
       let value = cacheExtra[slot] {
        return value
    }

    guard let cacheData = mgspoofparsecachedata(dict) else { return nil }
    if let direct = cacheData[readable] { return direct }
    let canonical = mgspoofcanonicalkey(readable)
    if let direct = cacheData[canonical] { return direct }
    if let symbolic = mgspoofkeymap[canonical] {
        return cacheData[symbolic]
    }
    return nil
}

/// Current values from the MobileGestalt cache for the UI. `unmapped` lists
/// readable keys that have no CacheExtra slot on this build (read-only mode).
func mgspoofreadvalues() -> mgspoofvalues {
    var result = mgspoofvalues()

    guard let dict = mgspoofreadcache() else {
        result.message = "could not read \(mgCurrentPath) (sandbox escape or VFS not ready?)"
        return result
    }

    let cacheExtra = dict["CacheExtra"] as? NSDictionary
    result.ok = true
    result.message = "ok"

    for key in mgspoofreadkeys {
        if let value = mgspooffindvalue(key, in: dict) {
            result.values[key] = mgspoofstring(from: value)
            result.present.append(key)
        }
        let mapped = cacheExtra.flatMap { mgspooffindkey(key, in: $0) }
        if mapped == nil {
            result.unmapped.append(key)
        }
    }

    return result
}

/// The device's real version values, read without MobileGestalt. These are
/// what kern.osversion / ProcessInfo readers keep seeing even while the cache
/// is spoofed, and are shown as a sanity check in the UI.
func mgspoofrealvalues() -> [String: String] {
    var out: [String: String] = [:]

    let osversion = mgspoofkernosversion()
    if !osversion.isEmpty {
        out["BuildVersion"] = osversion
    }

    let version = ProcessInfo.processInfo.operatingSystemVersion
    var product = "\(version.majorVersion).\(version.minorVersion)"
    if version.patchVersion > 0 {
        product += ".\(version.patchVersion)"
    }
    out["ProductVersion"] = product
    return out
}

func mgspoofkernosversion() -> String {
    var size = 0
    guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
    return String(cString: buffer)
}

// MARK: - Safety backups (Documents/lara_backups)

func mgspoofbackupdir() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("lara_backups", isDirectory: true)
}

func mgspoofbackuppath() -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let name = "mgspoof-MobileGestalt-\(formatter.string(from: Date())).plist"
    return mgspoofbackupdir().appendingPathComponent(name)
}

/// Newest mgspoof backup, if any. Fixed-width timestamps sort chronologically.
func mgspooffindlatestbackup() -> URL? {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: mgspoofbackupdir().path) else { return nil }
    let candidates = names
        .filter { $0.hasPrefix("mgspoof-MobileGestalt-") && $0.hasSuffix(".plist") }
        .sorted()
    guard let latest = candidates.last else { return nil }
    return mgspoofbackupdir().appendingPathComponent(latest)
}

/// Copies the current MobileGestalt cache into Documents/lara_backups once per
/// call (every apply gets its own timestamped snapshot). Never overwrites an
/// older backup.
@discardableResult
func mgspoofbackupcache() -> (ok: Bool, message: String) {
    let mgr = laramgr.shared
    let fm = FileManager.default

    guard fm.fileExists(atPath: mgCurrentPath) else {
        return (false, "no MobileGestalt cache at \(mgCurrentPath)")
    }

    do {
        try fm.createDirectory(at: mgspoofbackupdir(), withIntermediateDirectories: true, attributes: nil)
    } catch {
        return (false, "failed to create backup folder: \(error)")
    }

    guard let data = mgspoofreaddata(path: mgCurrentPath) else {
        return (false, "failed to read \(mgCurrentPath) for backup")
    }

    let dest = mgspoofbackuppath()
    do {
        try data.write(to: dest, options: .atomic)
        mgr.logmsg("(mgspoof) backed up MobileGestalt to \(dest.lastPathComponent) (\(data.count) bytes)")
        return (true, "backed up to \(dest.lastPathComponent)")
    } catch {
        return (false, "failed to write backup: \(error)")
    }
}

// MARK: - Validation

/// Build numbers look like 23A341 / 18B91: two digits, a letter, then 2-5
/// alphanumerics. Returns nil when valid, otherwise a human-readable reason.
func mgspoofvalidatebuildversion(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "BuildVersion is empty" }
    let pattern = "^[0-9]{2}[A-Za-z][0-9A-Za-z]{2,5}$"
    guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
        return "BuildVersion \"\(trimmed)\" does not look like a build number (expected e.g. 23A341)"
    }
    return nil
}

/// Product versions look like 26.0 / 26.0.1 / 17.4.1. Returns nil when valid,
/// otherwise a human-readable reason.
func mgspoofvalidateproductversion(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "ProductVersion is empty" }
    let pattern = "^[0-9]{1,2}(\\.[0-9]{1,2}){1,2}$"
    guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
        return "ProductVersion \"\(trimmed)\" does not look like a version (expected e.g. 26.0 or 26.0.1)"
    }
    return nil
}

// MARK: - Quiet plist validation

/// Serializes a MobileGestalt cache dictionary to binary plist data with the
/// same safety checks as GestaltView.verifyPlist(), but without the UI alerts
/// (these helpers run on a background queue). Throws a message string on any
/// problem so nothing corrupt can be written.
func mgspoofserializecache(_ plist: Any, targetPath: String) throws -> Data {
    let fm = FileManager.default

    if fm.fileExists(atPath: targetPath) {
        let attrs = try? fm.attributesOfItem(atPath: targetPath)
        if let current = attrs?[.size] as? NSNumber, current.intValue == 0 {
            throw "current MobileGestalt cache is already 0 bytes; refusing to overwrite"
        }
    }

    guard PropertyListSerialization.propertyList(plist, isValidFor: .binary) else {
        throw "invalid plist structure"
    }

    let data = try PropertyListSerialization.data(
        fromPropertyList: plist,
        format: .binary,
        options: 0
    )

    guard !data.isEmpty else {
        throw "serialized plist data is empty"
    }

    do {
        _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
        throw "serialized plist failed re-validation: \(error)"
    }

    return data
}

// MARK: - Apply / revert / restore

/// Writes new BuildVersion / ProductVersion values into CacheExtra and pushes
/// the cache back to disk through the sandbox escape. Requires mgr.sbxready
/// (same requirement as GestaltView.applyGestalt). A timestamped backup is
/// written before any modification; without a backup the write is refused.
func mgspoofapply(buildVersion: String, productVersion: String) -> (ok: Bool, message: String) {
    let mgr = laramgr.shared
    let build = buildVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    let product = productVersion.trimmingCharacters(in: .whitespacesAndNewlines)

    guard mgr.sbxready else {
        return (false, "sandbox escape (sbx) is not ready; MobileGestalt writes need it")
    }
    if let error = mgspoofvalidatebuildversion(build) { return (false, error) }
    if let error = mgspoofvalidateproductversion(product) { return (false, error) }

    guard let dict = mgspoofreadcache() else {
        return (false, "could not read MobileGestalt cache at \(mgCurrentPath)")
    }
    guard let cacheExtra = dict["CacheExtra"] as? NSMutableDictionary else {
        return (false, "CacheExtra missing from MobileGestalt cache")
    }
    guard let buildKey = mgspooffindkey("BuildVersion", in: cacheExtra) else {
        return (false, "no CacheExtra slot mapped for BuildVersion (read-only mode)")
    }
    guard let productKey = mgspooffindkey("ProductVersion", in: cacheExtra) else {
        return (false, "no CacheExtra slot mapped for ProductVersion (read-only mode)")
    }

    let backup = mgspoofbackupcache()
    guard backup.ok else {
        return (false, "refusing to write without a backup: \(backup.message)")
    }

    cacheExtra[buildKey] = build
    cacheExtra[productKey] = product

    do {
        let data = try mgspoofserializecache(dict, targetPath: mgCurrentPath)
        let result = mgr.lara_overwritefile(target: mgCurrentPath, data: data, fallback_vfs: false)
        if result.ok {
            let message = "wrote BuildVersion=\(build) [\(buildKey)] and ProductVersion=\(product) [\(productKey)] (\(backup.message))"
            mgr.logmsg("(mgspoof) \(message)")
            return (true, message)
        }
        let message = "overwrite failed: \(result.message)"
        mgr.logmsg("(mgspoof) \(message)")
        return (false, message)
    } catch {
        let message = "plist validation failed: \(error)"
        mgr.logmsg("(mgspoof) \(message)")
        return (false, message)
    }
}

/// Reverts the version spoof by removing the spoofed keys from CacheExtra, so
/// MGCopyAnswer falls back to the underlying system values. The pre-write
/// backups in Documents/lara_backups remain available for a full restore.
func mgspoofrevert() -> (ok: Bool, message: String) {
    let mgr = laramgr.shared

    guard mgr.sbxready else {
        return (false, "sandbox escape (sbx) is not ready; MobileGestalt writes need it")
    }
    guard let dict = mgspoofreadcache() else {
        return (false, "could not read MobileGestalt cache at \(mgCurrentPath)")
    }
    guard let cacheExtra = dict["CacheExtra"] as? NSMutableDictionary else {
        return (false, "CacheExtra missing from MobileGestalt cache")
    }

    var removed: [String] = []
    for key in mgspoofwritekeys {
        if let slot = mgspooffindkey(key, in: cacheExtra), cacheExtra[slot] != nil {
            cacheExtra.removeObject(forKey: slot)
            removed.append("\(key) [\(slot)]")
        }
    }

    guard !removed.isEmpty else {
        return (true, "nothing to revert (no BuildVersion/ProductVersion entry in CacheExtra)")
    }

    do {
        let data = try mgspoofserializecache(dict, targetPath: mgCurrentPath)
        let result = mgr.lara_overwritefile(target: mgCurrentPath, data: data, fallback_vfs: false)
        if result.ok {
            let message = "removed \(removed.joined(separator: ", "))"
            mgr.logmsg("(mgspoof) \(message)")
            return (true, message)
        }
        let message = "overwrite failed: \(result.message)"
        mgr.logmsg("(mgspoof) \(message)")
        return (false, message)
    } catch {
        let message = "plist validation failed: \(error)"
        mgr.logmsg("(mgspoof) \(message)")
        return (false, message)
    }
}

/// Restores the whole MobileGestalt cache from the newest mgspoof backup.
/// This also undoes any other MobileGestalt edits made after that backup.
func mgspoofrestorebackup() -> (ok: Bool, message: String) {
    let mgr = laramgr.shared

    guard mgr.sbxready else {
        return (false, "sandbox escape (sbx) is not ready; MobileGestalt writes need it")
    }
    guard let backup = mgspooffindlatestbackup() else {
        return (false, "no mgspoof backup found in Documents/lara_backups")
    }

    let result = mgr.lara_overwritefile(target: mgCurrentPath, source: backup.path, fallback_vfs: false)
    if result.ok {
        let message = "restored \(mgCurrentPath) from \(backup.lastPathComponent)"
        mgr.logmsg("(mgspoof) \(message)")
        return (true, message)
    }
    let message = "restore failed: \(result.message)"
    mgr.logmsg("(mgspoof) \(message)")
    return (false, message)
}
