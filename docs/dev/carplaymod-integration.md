# CarPlay Mod — integration notes

Status: **new, unbuilt** (written without access to Xcode). Logic + UI are additive only;
no existing file was modified. Review before shipping.

Target device class: **iPhone14,6 / iOS 26.0 (23A341)**. Some facts below were verified
against the extracted restore image in this repo (`carplay_extract/23A341__iPhone14,6/`).

## Files

| File | Role |
| --- | --- |
| `lara/lara/CarPlay/CarPlayModInstaller.swift` | All logic: wallpaper encode/replace, asset scan, capability overrides, denylist read/clear, backups. |
| `lara/lara/views/tweaks/carplay/CarPlayModView.swift` | `CarPlayModView` + `CarPlayCapabilitiesEditorView` + `CarPlayDenylistView`. |
| `lara/docs/dev/carplaymod-integration.md` | This document. |

Source files live under the app's `lara/` folder because the Xcode project uses a
`PBXFileSystemSynchronizedRootGroup` (`path = lara`); any new file in that tree is compiled
automatically. **No `.xcodeproj` change is needed.**

## Wiring into TweaksView.swift

`TweaksView.swift` is not modified by this toolkit. Add one entry, e.g. a new section
between "User Interface" and "System", or as a row in "System":

```swift
Section(header: HeaderLabel(text: "CarPlay", icon: "car.fill")) {
    NavigationLink("CarPlay Mod", destination: CarPlayModView(mgr: mgr))
        .disabled(!mgr.dsready)
}
```

`mgr.dsready` is the outer gate (the whole Tweaks list is already disabled until the
exploit runs). Inside `CarPlayModView`:

| Operation | Gate |
| --- | --- |
| Wallpaper replace / wallpaper restore | `mgr.vfsready` (SSV overlay, same as `FontPicker`) |
| Asset scan, capability apply/restore, denylist read/clear | `mgr.sbxready` (data volume) |
| Image import to Documents | none (app container) |

## 1. Wallpaper replacement

Paths (all 12 exist on 23A341):

```
/System/Library/PrivateFrameworks/CarPlayUIServices.framework/Wallpaper{Blue,Brown,Gray,Green,Purple,Red}-{Light,Dark}.heic
```

Observed sizes on 26.0/23A341: **1,056,853 – 1,218,475 bytes** (~1.01–1.16 MiB).
The list is hard-coded in `CarPlayModInstaller.wallpapers`; sizes are read at runtime with
`mgr.vfssize(path:)`.

How the write works:

1. The picked file (`.heic`/`.jpg`/`.png`) is copied into
   `Documents/CarPlayWallpapers/` while the security-scoped URL is valid.
2. `prepareWallpaperData(atPath:maxBytes:)`:
   - `.heic`/`.heif` already ≤ cap → passed through byte-for-byte.
   - otherwise decoded with `UIImage`, orientation-normalized, encoded to HEIC with
     `CGImageDestination` (`UTType.heic`) in a two-stage loop: quality 0.9→0.3, then
     downscale by `sqrt(cap/size)·0.9` (up to 12 iterations, stops below 96 px).
     If it still does not fit, the install is **refused**.
3. The original is backed up first (`Documents/lara_backups/…`).
4. Data is zero-padded to the original size and written with
   `mgr.vfsoverwritewithdata(target:data:)`.

Why padding: `vfs_overwritefile()` (kexploit/pe/vfs.m) maps the target, requires
`source_size <= target_size`, and zeroes the trailing bytes itself. Passing exact-size data
is equivalent and keeps the "≤ original size, tail zeroed" rule explicit in Swift.

Notes / risks:

- This is the same SSV in-memory overlay mechanism `FontPicker` uses; **it reverts on
  reboot** and possibly on framework reload. CarPlay may need a reconnect (or respring)
  before the head unit shows the new image.
- The overlay patch happens in the app process's mapping; other processes may cache the
  old wallpaper. Not verified on device.
- HEIC encoding quality support and alpha handling were not device-tested.
- Very large images are capped at 3000 px before encoding; memory during encode can still
  spike (~4 bytes/px).

## 2. Per-car capability overrides

Discovery: `CarPlayModInstaller.scanAssets()` walks `/private/var/MobileAsset` recursively
(covers both `PreinstalledAssetsV2/InstallWithOs/com_apple_MobileAsset_CarExperienceAssets/…`
and downloaded `AssetsV2/…`) and collects every `CarPlayCapabilities.plist`
(cap: 64 results). Multiple assets are normal — the UI offers per-file editing and an
"apply to all" editor.

Observed schema (binary plist, 23A341 preinstalled asset):

```
features:  { dashboardRoundedCorners: "{{13, 0}, {0, 0}}", nowPlayingAlbumArt: "2",
             rightHandDriveFlip: "0", userInterfaceStyle: "2",
             viewAreaInsets: "{{0, 0}, {0, 0}}", userInfo: {}, zoomFactor: "" }
vehicles:  [ { features: { rightHandDriveFlip: "0", userInterfaceStyle: "0" },
               vehicleManufacturer: "Toyota Multimedia", … }, … 132 entries ]
properties:[ … ]  version: "25"
```

All override values are **strings**, not numbers — the UI writes `"0"`/`"1"`/`"2"` and the
`"{{0, 0}, {0, 0}}"` string to stay schema-consistent.

Write behaviour (`applyCapabilityOverrides`):

- The root `features` dictionary always gets the selected keys (created if missing).
- Every `vehicles[i].features` dictionary is only touched when it **already defines the
  same key** — this overrides per-car values without adding the key to all 132 entries.
  Cars without the key inherit the root value.
- Plist format (binary/xml) is preserved; `version` is not bumped.
- Backup is written before the first change; the plist is then written with a plain
  `Data.write` (data volume, needs SBX).

Notes / risks:

- The asset daemon can restore stock files at any time, including after reboot. Reapply as
  needed — this is stated in the UI footer.
- `dashboardRoundedCorners` was not present in any `vehicles[i].features` on stock; the
  square-corners override therefore mainly lives in root `features`.
- `userInterfaceStyle` semantics (0 = auto, 1 = light, 2 = dark) are inferred from the
  stock values, not documented by Apple.
- Changing the file may cause the asset daemon to re-validate/re-download the asset; not
  verified on device.

## 3. App / widget / Live Activity denylists

The same scan also finds (same `AssetData` directories):

```
CarPlayAppDenylist.plist            -> [ "com.apple.carplay.blacklisted", "com.apple.carplay.blacklisted-nav" ]
CarPlayWidgetDenyList.plist         -> [ "com.apple.group:com.apple.group.widgetName:com.apple.group.kind" ]
CarPlayLiveActivitiesDenylist.plist -> [ "com.apple.carplay.blacklisted", "com.apple.carplay.blacklisted-nav" ]
```

Stock contents are placeholders only. The UI is a read-only viewer (array entries shown
monospaced; dictionaries shown as `key: value` lines) plus a destructive **Clear Entries**
button which backs up first and writes an empty container of the same kind (`[]` or `{}`).

Risks: clearing placeholders is very likely a no-op behaviourally; writing malformed data
could make the daemon treat the asset as corrupt, which is why the backup is mandatory and
the plist format is preserved.

## Backups

Location: `Documents/lara_backups/`.

- `<stem>.bak` — raw original bytes.
- `<stem>.origin` — UTF-8 absolute path of the original file.
- `stem = sanitized path (≤140 chars, tail kept) + "-" + FNV-1a hash`, so names stay under
  filesystem limits and collisions are practically impossible.

Policy: **first-seen original wins** — an existing backup is never overwritten. The
"Restore Backup" section lists every backup with size/date and a Restore button; SSV files
are restored through `vfsoverwritewithdata`, data-volume files with a plain write. The
capabilities editor also has "Restore Originals" for its file list.

## Logging

Every action logs through `globallogger` with a `(carplay)` prefix (import, encode result,
backup, overwrite, scan counts, clear, restore, and failure reasons). The view's status
line mirrors the last result.

## Open questions / uncertainties

1. **Compile-time**: files were written without Xcode; they follow `FontPicker.swift` /
   `PasscodeView.swift` patterns, but the build must confirm SwiftUI overloads
   (`alert(_:isPresented:presenting:)`, `fileImporter`, `onChange(of:perform:)`).
2. **SSV overlay scope**: whether `CarPlayUIServices` (and `CarPlayWallpaper.app`) pick up
   the patched bytes without a respring/reconnect was not verified.
3. **Capability key semantics**: only `dashboardRoundedCorners`, `userInterfaceStyle`,
   `rightHandDriveFlip`, `viewAreaInsets` are handled; `zoomFactor`, `nowPlayingAlbumArt`
   and `userInfo` are displayed but not editable.
4. **Daemon restore**: exact cadence of MobileAsset revalidation/restoration is unknown.
5. **Multiple assets**: "apply to all" writes every discovered capability plist; on a
   device with several downloaded assets this may be more than intended. Per-file editing
   is available.

## Suggested device test checklist

- [ ] `CarPlayModView` opens from Tweaks; sections render with exploit off (disabled) and on.
- [ ] VFS ready → sizes appear for all 12 wallpapers; replace one with a small HEIC, one
      with a JPG > cap (expect downscale), one with an impossible image (expect refusal).
- [ ] After replacement, verify size via `mgr.vfssize` and that the tail is zeroed.
- [ ] Restore from backup reproduces the original bytes (checksum compare).
- [ ] SBX ready → scan finds the preinstalled asset; editor shows current feature values.
- [ ] Apply `dashboardRoundedCorners` + `userInterfaceStyle`; re-read the plist to confirm
      strings and untouched `vehicles` entries; restore and re-read.
- [ ] Denylist viewer shows placeholder entries; clear writes `[]`; restore works.
- [ ] Reboot → wallpaper reverts; capability/denylist changes persist until the daemon
      rewrites them.
