//
//  CarPlayModInstaller.swift
//  lara
//
//  CarPlay Mod toolkit — logic layer.
//
//  Three features:
//   1. Wallpaper replacement: overwrites the 12 CarPlayUIServices wallpapers
//      through laramgr's VFS in-memory overlay (reverts on reboot). The VFS
//      overlay keeps the original file size, so replacements are size-capped
//      and the tail is zero-padded.
//   2. Per-car capability overrides: edits features/vehicles entries inside
//      CarPlayCapabilities.plist assets under /private/var/MobileAsset.
//   3. App/widget/Live Activity denylist management: read + clear the three
//      CarPlay*Deny*.plist files found next to the capability asset.
//
//  All first-seen originals are backed up to Documents/lara_backups/ before
//  any write, with a ".origin" sidecar storing the absolute target path.
//
//  UI lives in views/tweaks/carplay/CarPlayModView.swift. No UI in this file.
//

import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Wallpaper model

struct CarPlayWallpaper: Identifiable, Hashable {
    let color: String
    let variant: String

    var id: String { filename }
    var filename: String { "Wallpaper\(color)-\(variant).heic" }
    var path: String { CarPlayModInstaller.wallpaperDirectory + "/" + filename }
    var displayName: String { "\(color) — \(variant)" }
}

// MARK: - Scan / backup / plist models

struct CarPlayAssetScan {
    var capabilities: [String] = []
    var denylists: [String] = []

    var isEmpty: Bool { capabilities.isEmpty && denylists.isEmpty }
}

struct CarPlayBackupEntry: Identifiable {
    let backupPath: String
    let originalPath: String
    let createdAt: Date?
    let size: Int64

    var id: String { backupPath }
    var isSystemFile: Bool { originalPath.hasPrefix("/System/") }
    var filename: String { (originalPath as NSString).lastPathComponent }
}

struct CarPlayDenylistContents {
    var rootKind: String = "unknown"
    var entries: [String] = []
    var clearable: Bool = false
}

struct CarPlayCapabilitySnapshot {
    var hasFeatures: Bool = false
    var hasVehicles: Bool = false
    var featureValues: [String: String] = [:]
    var vehicleOverrideCount: Int = 0
}

// MARK: - Override options

enum CarPlayInterfaceStyle: Int, CaseIterable, Identifiable {
    case unchanged = -1
    case automatic = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .unchanged: return "Leave unchanged"
        case .automatic: return "Automatic (0)"
        case .light: return "Light (1)"
        case .dark: return "Dark (2)"
        }
    }
}

enum CarPlayFlipMode: Int, CaseIterable, Identifiable {
    case unchanged = -1
    case off = 0
    case on = 1

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .unchanged: return "Leave unchanged"
        case .off: return "Off (0)"
        case .on: return "On (1)"
        }
    }
}

struct CarPlayCapabilityOverrides {
    var squareDashboardCorners: Bool = false
    var userInterfaceStyle: CarPlayInterfaceStyle = .unchanged
    var rightHandDriveFlip: CarPlayFlipMode = .unchanged
    var viewAreaInsets: String = ""

    var isNoop: Bool {
        !squareDashboardCorners &&
        userInterfaceStyle == .unchanged &&
        rightHandDriveFlip == .unchanged &&
        viewAreaInsets.isEmpty
    }
}

// MARK: - Installer

final class CarPlayModInstaller {
    static let shared = CarPlayModInstaller()

    /// SSV directory holding the 12 CarPlay wallpaper HEICs (iOS 26.0).
    static let wallpaperDirectory = "/System/Library/PrivateFrameworks/CarPlayUIServices.framework"

    /// Root of the MobileAsset store (contains PreinstalledAssetsV2 and AssetsV2).
    static let mobileAssetRoot = "/private/var/MobileAsset"

    static let capabilitiesFilename = "CarPlayCapabilities.plist"

    static let denylistFilenames = [
        "CarPlayAppDenylist.plist",
        "CarPlayWidgetDenyList.plist",
        "CarPlayLiveActivitiesDenylist.plist",
    ]

    /// Keys this toolkit is allowed to override in features dictionaries.
    static let overridableKeys = [
        "dashboardRoundedCorners",
        "userInterfaceStyle",
        "rightHandDriveFlip",
        "viewAreaInsets",
    ]

    /// Value used for "square" dashboard corners.
    static let squareCornersValue = "{{0, 0}, {0, 0}}"

    /// The 12 stock wallpapers (6 colors × Light/Dark).
    static let wallpapers: [CarPlayWallpaper] = {
        let colors = ["Blue", "Brown", "Gray", "Green", "Purple", "Red"]
        let variants = ["Light", "Dark"]
        var result: [CarPlayWallpaper] = []
        for color in colors {
            for variant in variants {
                result.append(CarPlayWallpaper(color: color, variant: variant))
            }
        }
        return result
    }()

    private init() {}

    private let fm = FileManager.default

    // MARK: - Paths

    var backupDirectory: String {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("lara_backups", isDirectory: true).path
    }

    var uploadDirectory: String {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("CarPlayWallpapers", isDirectory: true).path
    }

    // MARK: - Helpers

    private func failure(_ message: String) -> (ok: Bool, message: String) {
        globallogger.log("(carplay) failed: \(message)")
        return (false, message)
    }

    static func byteString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func padded(_ data: Data, to size: Int) -> Data {
        guard data.count < size else { return data }
        var out = data
        out.append(Data(count: size - data.count))
        return out
    }

    /// Stable, filesystem-safe backup name for an absolute path.
    static func backupStem(for path: String) -> String {
        var name = path.replacingOccurrences(of: "/", with: "_")
        if name.count > 140 {
            name = String(name.suffix(140))
        }
        return name + "-" + stableHash(path)
    }

    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    static func describe(entry: Any?) -> String {
        guard let entry = entry else { return "nil" }
        if let string = entry as? String { return string }
        if let number = entry as? NSNumber { return number.stringValue }
        if let array = entry as? [Any] {
            return "[" + array.map { describe(entry: $0) }.joined(separator: ", ") + "]"
        }
        if let dict = entry as? [String: Any] {
            let keys = dict.keys.sorted().prefix(8)
            let body = keys.map { "\($0): \(describe(entry: dict[$0]))" }.joined(separator: ", ")
            return "{" + body + "}"
        }
        return String(describing: entry)
    }

    // MARK: - Backups

    /// Copies the first-seen original of `originalPath` into Documents/lara_backups.
    /// Returns true when a backup exists afterwards (created now or earlier).
    @discardableResult
    func backupIfNeeded(originalPath: String) -> Bool {
        try? fm.createDirectory(atPath: backupDirectory, withIntermediateDirectories: true)

        let stem = CarPlayModInstaller.backupStem(for: originalPath)
        let backupPath = backupDirectory + "/" + stem + ".bak"
        if fm.fileExists(atPath: backupPath) {
            // never trust an existing backup we cannot verify (e.g. truncated by an interrupted write)
            if let attrs = try? fm.attributesOfItem(atPath: backupPath),
               let size = attrs[.size] as? Int64, size > 0 {
                return true
            }
            try? fm.removeItem(atPath: backupPath)
        }

        guard let data = readOriginalData(path: originalPath) else {
            globallogger.log("(carplay) backup failed: could not read \(originalPath)")
            return false
        }

        let originPath = backupDirectory + "/" + stem + ".origin"
        do {
            // write to a temp name and rename so an interrupted write can never look like a valid backup
            let tmpPath = backupPath + ".tmp"
            try data.write(to: URL(fileURLWithPath: tmpPath))
            if fm.fileExists(atPath: backupPath) { try fm.removeItem(atPath: backupPath) }
            try fm.moveItem(atPath: tmpPath, toPath: backupPath)
            try Data(originalPath.utf8).write(to: URL(fileURLWithPath: originPath))
            globallogger.log("(carplay) backup saved: \(backupPath) (\(data.count) bytes)")
            return true
        } catch {
            globallogger.log("(carplay) backup write failed for \(originalPath): \(error.localizedDescription)")
            try? fm.removeItem(atPath: backupDirectory + "/" + stem + ".tmp")
            return false
        }
    }

    func listBackups() -> [CarPlayBackupEntry] {
        guard let names = try? fm.contentsOfDirectory(atPath: backupDirectory) else { return [] }

        var entries: [CarPlayBackupEntry] = []
        for name in names where name.hasSuffix(".bak") {
            let backupPath = backupDirectory + "/" + name
            let originURL = URL(fileURLWithPath: backupPath)
                .deletingPathExtension()
                .appendingPathExtension("origin")
            guard let originData = try? Data(contentsOf: originURL),
                  let raw = String(data: originData, encoding: .utf8) else { continue }
            let originalPath = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !originalPath.isEmpty else { continue }

            let attrs = try? fm.attributesOfItem(atPath: backupPath)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let created = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)

            entries.append(CarPlayBackupEntry(
                backupPath: backupPath,
                originalPath: originalPath,
                createdAt: created,
                size: size
            ))
        }

        return entries.sorted { $0.originalPath < $1.originalPath }
    }

    func backupEntry(forOriginalPath path: String) -> CarPlayBackupEntry? {
        listBackups().first { $0.originalPath == path }
    }

    func hasBackup(forOriginalPath path: String) -> Bool {
        fm.fileExists(atPath: backupDirectory + "/" + CarPlayModInstaller.backupStem(for: path) + ".bak")
    }

    /// Restores a backup entry to its original location.
    /// SSV paths (/System/...) go through the VFS overlay; data-volume paths
    /// use a plain FileManager write (requires the sandbox escape).
    func restoreBackup(_ entry: CarPlayBackupEntry) -> (ok: Bool, message: String) {
        guard fm.fileExists(atPath: entry.backupPath) else {
            return failure("backup file missing: \(entry.backupPath)")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: entry.backupPath)) else {
            return failure("could not read backup: \(entry.backupPath)")
        }

        let result = writeData(target: entry.originalPath, data: data)
        if result.ok {
            globallogger.log("(carplay) restored \(entry.originalPath) from backup")
        } else {
            globallogger.log("(carplay) restore failed for \(entry.originalPath): \(result.message)")
        }
        return result
    }

    private func readOriginalData(path: String) -> Data? {
        if path.hasPrefix("/System/") {
            return vfsReadWholeFile(path: path)
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return data
        }
        return vfsReadWholeFile(path: path)
    }

    private func vfsReadWholeFile(path: String) -> Data? {
        guard laramgr.shared.vfsready else { return nil }
        let size = laramgr.shared.vfssize(path: path)
        guard size > 0, size < 256 * 1024 * 1024 else { return nil }
        return laramgr.shared.vfsread(path: path, maxSize: Int(size))
    }

    private func writeData(target: String, data: Data) -> (ok: Bool, message: String) {
        if target.hasPrefix("/System/") {
            guard laramgr.shared.vfsready else { return failure("vfs not ready") }
            let current = laramgr.shared.vfssize(path: target)
            guard current > 0 else { return failure("could not stat \(target)") }
            guard data.count <= Int(current) else {
                return failure("data (\(data.count) bytes) is larger than the original file (\(current) bytes)")
            }
            let out = CarPlayModInstaller.padded(data, to: Int(current))
            guard laramgr.shared.vfsoverwritewithdata(target: target, data: out) else {
                return failure("vfs overwrite failed for \(target)")
            }
            return (true, "vfs overwrite ok (\(data.count) bytes)")
        }

        guard laramgr.shared.sbxready else { return failure("sandbox escape not ready") }
        do {
            try data.write(to: URL(fileURLWithPath: target))
            return (true, "wrote \(data.count) bytes")
        } catch {
            return failure("write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Wallpapers

    func originalWallpaperSize(for wallpaper: CarPlayWallpaper) -> Int64 {
        guard laramgr.shared.vfsready else { return -1 }
        return laramgr.shared.vfssize(path: wallpaper.path)
    }

    /// Copies a picked image into Documents so it stays reachable after the
    /// file-importer callback returns.
    func importWallpaperImage(from url: URL) -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let name = url.lastPathComponent
        guard !name.isEmpty else {
            globallogger.log("(carplay) image import failed: empty filename")
            return nil
        }

        try? fm.createDirectory(atPath: uploadDirectory, withIntermediateDirectories: true)
        let dest = uploadDirectory + "/" + name

        do {
            if fm.fileExists(atPath: dest) {
                try fm.removeItem(atPath: dest)
            }
            try fm.copyItem(at: url, to: URL(fileURLWithPath: dest))
            globallogger.log("(carplay) imported wallpaper image: \(name)")
            return dest
        } catch {
            globallogger.log("(carplay) image import failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Replaces one wallpaper. `imagePath` must be a local file (use
    /// importWallpaperImage first). Refuses when the image cannot be encoded
    /// to a HEIC that fits in the original file size.
    func installWallpaper(_ wallpaper: CarPlayWallpaper, imagePath: String) -> (ok: Bool, message: String) {
        guard laramgr.shared.vfsready else { return failure("vfs not ready") }

        let originalSize = laramgr.shared.vfssize(path: wallpaper.path)
        guard originalSize > 0 else {
            return failure("could not read original size for \(wallpaper.filename)")
        }
        guard fm.fileExists(atPath: imagePath) else {
            return failure("image not found: \(imagePath)")
        }

        guard let prepared = CarPlayModInstaller.prepareWallpaperData(atPath: imagePath, maxBytes: Int(originalSize)) else {
            return failure("could not fit the image into \(CarPlayModInstaller.byteString(Int(originalSize)))")
        }

        guard backupIfNeeded(originalPath: wallpaper.path) else {
            return failure("backup failed — refusing to overwrite \(wallpaper.filename)")
        }

        let out = CarPlayModInstaller.padded(prepared, to: Int(originalSize))
        guard laramgr.shared.vfsoverwritewithdata(target: wallpaper.path, data: out) else {
            return failure("vfs overwrite failed for \(wallpaper.filename)")
        }

        globallogger.log("(carplay) replaced \(wallpaper.filename) (\(prepared.count) bytes, cap \(originalSize) bytes)")
        return (true, "replaced \(wallpaper.displayName)")
    }

    /// Loads an image and returns HEIC bytes that fit in `maxBytes`, or nil.
    /// Already-fitting HEIC input is passed through untouched.
    static func prepareWallpaperData(atPath path: String, maxBytes: Int) -> Data? {
        guard maxBytes > 0 else { return nil }
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }

        let ext = (path as NSString).pathExtension.lowercased()
        if (ext == "heic" || ext == "heif") && raw.count <= maxBytes {
            return raw
        }

        guard let image = UIImage(data: raw) else { return nil }
        return heicDataFitting(image, maxBytes: maxBytes)
    }

    private static func heicDataFitting(_ image: UIImage, maxBytes: Int) -> Data? {
        var working = normalized(image)

        // Cap absurdly large inputs before the quality loop.
        let maxDimension: CGFloat = 3000
        let largest = max(working.size.width, working.size.height)
        if largest > maxDimension {
            working = scaled(working, by: maxDimension / largest)
        }

        var quality: CGFloat = 0.9
        for _ in 0..<5 {
            if let data = heicData(from: working, quality: quality), data.count <= maxBytes {
                return data
            }
            quality = max(0.3, quality - 0.15)
        }

        for _ in 0..<12 {
            guard let data = heicData(from: working, quality: 0.5) else { return nil }
            if data.count <= maxBytes { return data }

            let ratio = (Double(maxBytes) / Double(data.count)).squareRoot() * 0.9
            let factor = max(0.2, min(0.9, ratio))
            let next = scaled(working, by: CGFloat(factor))
            if next.size.width < 96 || next.size.height < 96 { return nil }
            if next.size == working.size { return nil }
            working = next
        }

        return nil
    }

    private static func heicData(from image: UIImage, quality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func normalized(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up && image.scale == 1 {
            return image
        }
        let size = pixelSize(of: image)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func scaled(_ image: UIImage, by factor: CGFloat) -> UIImage {
        let current = pixelSize(of: image)
        let newSize = CGSize(
            width: max(1, (current.width * factor).rounded()),
            height: max(1, (current.height * factor).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(
            width: max(1, image.size.width * image.scale),
            height: max(1, image.size.height * image.scale)
        )
    }

    // MARK: - Asset discovery

    /// Walks /private/var/MobileAsset and collects the capability + denylist
    /// plists (covers both PreinstalledAssetsV2 and downloaded AssetsV2).
    func scanAssets() -> CarPlayAssetScan {
        var scan = CarPlayAssetScan()

        guard fm.fileExists(atPath: CarPlayModInstaller.mobileAssetRoot) else {
            globallogger.log("(carplay) scan failed: \(CarPlayModInstaller.mobileAssetRoot) not found")
            return scan
        }
        guard let enumerator = fm.enumerator(atPath: CarPlayModInstaller.mobileAssetRoot) else {
            globallogger.log("(carplay) scan failed: could not enumerate MobileAsset")
            return scan
        }

        var visited = 0
        for case let relative as String in enumerator {
            visited += 1
            if visited > 200000 { break }

            let name = (relative as NSString).lastPathComponent
            let fullPath = CarPlayModInstaller.mobileAssetRoot + "/" + relative

            if name == CarPlayModInstaller.capabilitiesFilename {
                if scan.capabilities.count < 64 { scan.capabilities.append(fullPath) }
            } else if CarPlayModInstaller.denylistFilenames.contains(name) {
                if scan.denylists.count < 64 { scan.denylists.append(fullPath) }
            }
        }

        scan.capabilities.sort()
        scan.denylists.sort()
        globallogger.log("(carplay) scan: \(scan.capabilities.count) capability plist(s), \(scan.denylists.count) denylist plist(s)")
        return scan
    }

    // MARK: - Capability overrides

    func inspectCapabilities(path: String) -> CarPlayCapabilitySnapshot {
        var snapshot = CarPlayCapabilitySnapshot()
        guard laramgr.shared.sbxready else { return snapshot }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return snapshot }

        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            return snapshot
        }
        guard let root = plist as? [String: Any] else { return snapshot }

        if let features = root["features"] as? [String: Any] {
            snapshot.hasFeatures = true
            for (key, value) in features {
                snapshot.featureValues[key] = CarPlayModInstaller.describe(entry: value)
            }
        }

        if let vehicles = root["vehicles"] as? [Any] {
            snapshot.hasVehicles = true
            for case let vehicle as [String: Any] in vehicles {
                guard let features = vehicle["features"] as? [String: Any] else { continue }
                if CarPlayModInstaller.overridableKeys.contains(where: { features[$0] != nil }) {
                    snapshot.vehicleOverrideCount += 1
                }
            }
        }

        return snapshot
    }

    /// Applies overrides to one CarPlayCapabilities.plist.
    ///
    /// The asset schema (observed on iOS 26.0 / 23A341) is:
    ///   features: [String: String]  — global defaults
    ///   vehicles: [[String: Any]]   — per-car dicts with their own
    ///                                 `features` dictionaries that win over
    ///                                 the global defaults.
    /// We always write the global `features`; per-vehicle features entries are
    /// only touched when they already define the same key (so we override
    /// existing per-car values without bloating all 132 entries).
    func applyCapabilityOverrides(path: String, overrides: CarPlayCapabilityOverrides) -> (ok: Bool, message: String) {
        guard !overrides.isNoop else { return failure("no overrides selected") }
        guard laramgr.shared.sbxready else { return failure("sandbox escape not ready") }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return failure("could not read \(path)")
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [.mutableContainersAndLeaves],
                format: &format
            )
        } catch {
            return failure("could not parse \(path): \(error.localizedDescription)")
        }
        guard let root = plist as? NSMutableDictionary else {
            return failure("\(path) root is not a dictionary")
        }

        let features: NSMutableDictionary
        if let existing = root["features"] {
            guard let mutable = existing as? NSMutableDictionary else {
                return failure("features in \(path) is not a dictionary — refusing to edit")
            }
            features = mutable
        } else {
            let created = NSMutableDictionary()
            root["features"] = created
            features = created
        }

        var applied = CarPlayModInstaller.applyOverrides(to: features, overrides: overrides, vehiclesOnly: false)

        if let vehicles = root["vehicles"] as? [Any] {
            for item in vehicles {
                guard let vehicle = item as? NSMutableDictionary,
                      let vehicleFeatures = vehicle["features"] as? NSMutableDictionary else { continue }
                applied += CarPlayModInstaller.applyOverrides(
                    to: vehicleFeatures,
                    overrides: overrides,
                    vehiclesOnly: true
                )
            }
        }

        guard applied > 0 else {
            return failure("no matching features dictionaries found in \(path)")
        }

        guard backupIfNeeded(originalPath: path) else {
            return failure("backup failed — refusing to write \(path)")
        }

        do {
            let out = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
            try out.write(to: URL(fileURLWithPath: path), options: .atomic)
            globallogger.log("(carplay) applied \(applied) override(s) to \(path)")
            return (true, "applied \(applied) override(s)")
        } catch {
            return failure("write failed for \(path): \(error.localizedDescription)")
        }
    }

    private static func applyOverrides(
        to features: NSMutableDictionary,
        overrides: CarPlayCapabilityOverrides,
        vehiclesOnly: Bool
    ) -> Int {
        var applied = 0

        if overrides.squareDashboardCorners,
           !vehiclesOnly || features["dashboardRoundedCorners"] != nil {
            features["dashboardRoundedCorners"] = CarPlayModInstaller.squareCornersValue
            applied += 1
        }

        if overrides.userInterfaceStyle != .unchanged,
           !vehiclesOnly || features["userInterfaceStyle"] != nil {
            features["userInterfaceStyle"] = String(overrides.userInterfaceStyle.rawValue)
            applied += 1
        }

        if overrides.rightHandDriveFlip != .unchanged,
           !vehiclesOnly || features["rightHandDriveFlip"] != nil {
            features["rightHandDriveFlip"] = String(overrides.rightHandDriveFlip.rawValue)
            applied += 1
        }

        if !overrides.viewAreaInsets.isEmpty,
           !vehiclesOnly || features["viewAreaInsets"] != nil {
            features["viewAreaInsets"] = overrides.viewAreaInsets
            applied += 1
        }

        return applied
    }

    // MARK: - Denylists

    func readDenylist(path: String) -> CarPlayDenylistContents {
        var contents = CarPlayDenylistContents()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            contents.rootKind = "unreadable"
            return contents
        }

        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            contents.rootKind = "invalid"
            return contents
        }

        if let array = plist as? [Any] {
            contents.rootKind = "array"
            contents.clearable = true
            contents.entries = array.map { CarPlayModInstaller.describe(entry: $0) }
        } else if let dict = plist as? [String: Any] {
            contents.rootKind = "dictionary"
            contents.clearable = true
            contents.entries = dict.keys.sorted().map { key in
                "\(key): \(CarPlayModInstaller.describe(entry: dict[key]))"
            }
        } else {
            contents.rootKind = "unsupported"
            contents.entries = [String(describing: plist)]
        }

        return contents
    }

    /// Backs up the denylist and replaces it with an empty container of the
    /// same kind (array -> [], dictionary -> {}).
    func clearDenylist(path: String) -> (ok: Bool, message: String) {
        guard laramgr.shared.sbxready else { return failure("sandbox escape not ready") }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return failure("could not read \(path)")
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            return failure("could not parse \(path): \(error.localizedDescription)")
        }

        let empty: Any
        if plist is NSArray {
            empty = NSArray()
        } else if plist is NSDictionary {
            empty = NSMutableDictionary()
        } else {
            return failure("unsupported plist root in \(path) — refusing to clear")
        }

        guard backupIfNeeded(originalPath: path) else {
            return failure("backup failed — refusing to clear \(path)")
        }

        do {
            let out = try PropertyListSerialization.data(fromPropertyList: empty, format: format, options: 0)
            try out.write(to: URL(fileURLWithPath: path))
            globallogger.log("(carplay) cleared denylist \(path)")
            return (true, "cleared entries in \((path as NSString).lastPathComponent)")
        } catch {
            return failure("write failed for \(path): \(error.localizedDescription)")
        }
    }
}
