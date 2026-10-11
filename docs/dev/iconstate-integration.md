# Home Screen Icon Toolbox — `IconStateView` integration

Status: implemented, not yet built or device-tested.
Scope: hide/unhide app tracking, icon-state backup/restore, layout reset.

## 1. Files

| File | Purpose |
| --- | --- |
| `lara/views/tweaks/homescreen/IconStateView.swift` | The whole feature: `IconStateView` + private `IconStateAppPickerView`. |
| `docs/dev/iconstate-integration.md` | This document. |

The Swift file lives under the Xcode file-system synchronized root group
(`project.pbxproj` → `PBXFileSystemSynchronizedRootGroup` with `path = lara`),
so adding it to `lara/lara/views/tweaks/homescreen/` is enough — no
`.xcodeproj` edit is required. The only membership exception is `Info.plist`.

## 2. Surfacing the view

`TweaksView.swift` already has a **User Interface** section with
`Show Hidden Icons` (`TweaksView.swift:44-55`). Add the toolbox next to it:

```swift
Section(header: HeaderLabel(text: "User Interface", icon: "eye")) {
    NavigationLink("dirtyZero", destination: dirtyZeroView())
        .disabled(!mgr.vfsready)
    NavigationLink("Show Hidden Icons", destination: ShowHiddenIconsView(mgr: mgr))
        .disabled(!mgr.sbxready && !mgr.vfsready)
    // NEW
    NavigationLink("Icon Toolbox", destination: IconStateView(mgr: mgr))
        .disabled(!mgr.sbxready)
    NavigationLink("MobileGestalt", destination: GestaltView(mgr: mgr))
        .disabled(!mgr.sbxready)
    // ...
}
```

The toolbox is gated on `mgr.sbxready` only, because layout reset deletes
files (`FileManager.removeItem`) and VFS mode has no unlink primitive.

## 3. What was reused from `ShowHiddenIconsView.swift`

The feature intentionally extends the existing view instead of reinventing it:

| Reused thing | Where it lives | How `IconStateView` uses it |
| --- | --- | --- |
| `SBIconVisibility` key | `ShowHiddenIconsView.swift:11` | Same key constant. |
| GlobalPreferences path | `ShowHiddenIconsView.swift:12` → `fileloc.globalprefs.rawValue` (`GestaltView.swift:14-27`, `:20`) | Same path for every preference read/write. |
| `getplistvalue(path:key:)` read | `ShowHiddenIconsView.swift:136` → `laramgr.swift:650-666` | `loadall()` mirrors `loadState()`. |
| `setplistvalue(path:key:force:)` write | `ShowHiddenIconsView.swift:153-157` → `laramgr.swift:617-648` | Hide writes `(key, nil)` — the same "disable" write `setEnabled(false)` performs, i.e. the inverse of enabling the reveal. |
| Enable semantics (`true` = reveal) | `ShowHiddenIconsView.swift:144-168` | Status row shows the live value; hide forces it back to "off". |
| Remove-preference reset | `ShowHiddenIconsView.swift:170-172` | `resetlayout()` clears the key as part of reset. |
| Empty-file DB overwrite | `ShowHiddenIconsView.swift:174-202` (`dbPaths` `:183-187`, `lara_overwritefile` `:191`) | Backup/restore uses the same DB path set and the same `lara_overwritefile(target:data:)` primitive (`laramgr.swift:431-448`). |
| Gate pattern | `ShowHiddenIconsView.swift:123-125` | Same idea, tightened to `sbxready` per task requirements. |
| Status alert pattern | `ShowHiddenIconsView.swift:108-112` | Same `.alert(... .constant(status != nil))` idiom. |
| Info-button + `Alertinator` pattern | `ShowHiddenIconsView.swift:69-79`, `Alertinator.swift:28-40` | Risk explanations on hide and reset. |

Additional repo patterns reused:

- App enumeration: `mgr.getAppList()` (`laramgr.swift:576-615`), same source used by
  `PPHelper` and the DarkBoard icon themer.
- Respring: `mgr.respring()` (`laramgr.swift:202-204`) which flips
  `showrespring` (`:90`), consumed by the overlay in `lara.swift:82-88`. Success
  alerts use the `Alertinator` + `actionLabel: "Respring"` idiom from
  `GestaltView.swift:442`.
- File deletion under sandbox escape: `FileManager.removeItem` precedent in
  `VarCleanView.swift:160-194` (`:179`).
- Backup storage under `Documents` via
  `FileManager.default.urls(for: .documentDirectory, ...)`, e.g.
  `GestaltView.swift:374`, `Logger.swift:297`.

## 4. Mechanisms

### 4.1 App visibility (`SBIconVisibility`)

iOS 26 stores the "Show Hidden Icons on Home Screen" tweak (Nugget) as a
boolean in `/var/Managed Preferences/mobile/.GlobalPreferences.plist`:

- `true` → SpringBoard reveals hidden apps (Field Test, Continuity, and apps the
  user hid via iOS 18+ *Hide App*).
- absent/`false` → hidden apps stay hidden.

`ShowHiddenIconsView` writes `true` to enable the reveal. `IconStateView` only
ever *clears* the key ("hide state"), which is the inverse. There is no
supported per-app hidden flag that a third-party process can write; iOS' own
*Hide and Require Face ID* is what actually marks an app hidden. Therefore the
toolbox:

1. writes a safety backup,
2. clears `SBIconVisibility` (so a previous reveal cannot undo iOS hiding),
3. records the bundle ID in `@AppStorage("lara.iconstate.trackedhidden")` as a
   JSON array so the user has a visible, reversible list.

Unhide removes the entry and, when the list becomes empty, clears the key
again (no-op if already absent). This is deliberately conservative: no
IconState.plist surgery is attempted, because the `SBHIconStateArchiver`
schema is opaque and a bad write can force SpringBoard to rebuild the layout.

System-critical bundles are excluded from the picker (`com.apple.springboard`,
`com.apple.Preferences`, `com.apple.mobilephone`, `com.apple.InCallService`,
`com.apple.purplebuddy`, `com.apple.ScreenTimeAgent`, plus a
`com.apple.springboard` prefix check and Lara's own bundle ID).

### 4.2 Icon state files

| Name in backup | Live path |
| --- | --- |
| `IconState.plist` | `/var/mobile/Library/SpringBoard/IconState.plist` |
| `DesiredIconState.plist` | `/var/mobile/Library/SpringBoard/DesiredIconState.plist` |
| `applicationState.db` | `/var/mobile/Library/FrontBoard/applicationState.db` |
| `applicationState.db-wal` | same folder, `-wal` |
| `applicationState.db-shm` | same folder, `-shm` |

The DB path matches `ShowHiddenIconsView.rebuildApplicationStateDB()`
(`ShowHiddenIconsView.swift:183-187`). The toolbox never parses these files; it
only reads bytes, copies them, overwrites them, or deletes two of them.

### 4.3 Backup

- Root: `Documents/lara_backups/`.
- Folder: `<prefix>-yyyyMMdd-HHmmss` (`manual`, `pre-hide`, `pre-unhide`,
  `pre-restore`, `pre-reset`).
- Each folder gets every readable source file plus an XML `manifest.plist`
  (creation date, iOS version, prefix, per-file `exists`/`bytes`).
- Reads: `Data(contentsOf:)` first, `mgr.vfsread(path:maxSize:)`
  (`laramgr.swift:307-316`) as fallback.
- A failed safety backup aborts the destructive action.

### 4.4 Restore

- Lists backup folders newest-first with file count and total size.
- Confirmation alert → automatic `pre-restore` backup → for every source name
  present in the selected folder, `mgr.lara_overwritefile(target:data:)`
  (`laramgr.swift:431-448`, sbx with VFS fallback).
- Success alert offers **Respring** (`mgr.respring()`); the alert text advises a
  reboot instead when `applicationState.db` was restored (stale `-wal`/`-shm`).

### 4.5 Reset layout

- Confirmation alert → automatic `pre-reset` backup → `FileManager.removeItem`
  for `IconState.plist` and `DesiredIconState.plist` (the `resetremoves` flag in
  `iconsourcefiles`) → clear `SBIconVisibility` → clear the tracked list →
  success alert offers **Respring**.
- `applicationState.db` is intentionally *not* deleted here; that destructive
  rebuild stays in `ShowHiddenIconsView` where the reboot warning already lives.

## 5. Safety model

| Rule | Implementation |
| --- | --- |
| Destructive actions gated on sandbox escape | `canWrite = mgr.sbxready`; every mutating button `.disabled(isLoading \|\| !canWrite)`. |
| Confirmation alert first | Hide (picker), Unhide, Restore, Reset. |
| Automatic backup first | `makebackup(prefix:)` runs before every hide/unhide/restore/reset and aborts on failure. |
| Clear log | Every action logs `(icons) …` through `mgr.logmsg` (`laramgr.swift:164-169`, mirrors into `globallogger`); restore/reset also call `globallogger.divider()`. |
| No schema surgery | Icon state plists are treated as opaque blobs. |

## 6. Uncertainties / open questions

1. **True per-app hiding is not implemented.** `SBIconVisibility` is global
   (confirmed in Nugget's `tweak_loader.py`: `BasicPlistTweak(globalPreferences,
   "SBIconVisibility")`, UI text "Show Hidden Icons on Home Screen"). The
   toolbox cannot mark an arbitrary app hidden in SpringBoard's database; it
   tracks intent and keeps the reveal off. IconState.plist rewriting was
   rejected as too risky without device verification.
2. **`DesiredIconState.plist` semantics are unverified.** It is backed up and
   deleted on reset, but it may be an input or an output of SpringBoard; if it
   is not authoritative, deleting it alone may not change the layout.
3. **SpringBoard may rewrite `IconState.plist`** before the respring completes,
   in which case a reset may not visibly reset. Reboot is the fallback
   (documented in the UI footer).
4. **DB restore consistency.** Restoring `applicationState.db` while a newer
   `-wal`/`-shm` is live can resurrect old state; the UI tells the user to
   reboot. WAL/SHM files are backed up and restored only when they existed at
   backup time.
5. **File names as the restore contract.** Restore matches backup contents by
   the five known file names; a future iOS path change requires updating
   `iconsourcefiles`.
6. **VFS-only devices** can read/backup but cannot delete (no unlink), hence the
   `sbxready` gate.
7. **App list coverage.** `mgr.getAppList()` only reports bundles found in
   `/var/containers/Bundle/Application` plus MCM data containers; apps that live
   in `/Applications` (most Apple system apps) will not appear. That is
   intentional for a "user apps" picker.
8. **Tracking storage.** The hidden list lives in UserDefaults; deleting Lara
   loses the tracking list (the preference state remains, so nothing dangerous
   happens).
9. **Not built or device-tested.** This change was written without Xcode
   available; compile errors, if any, are most likely in the alert/binding
   plumbing or the `setplistvalue` tuple call (identical shape to
   `ShowHiddenIconsView.swift:153`).
10. **Backup name collisions** are possible if two actions run within the same
    second; the second run reuses the folder and overwrites its files
    (still safe, just fewer restore points).

## 7. Manual test checklist (on device)

1. Build, open **Tweaks → User Interface → Icon Toolbox** with `sbxready`.
2. Status section: file sizes match Filza/`ls`, app counts are plausible.
3. **Back Up Icon State Now** → folder appears in `Documents/lara_backups`,
   `manifest.plist` lists five files with correct byte counts.
4. **Restore** that backup immediately → all files overwritten, respring prompt.
5. **Hide an App** (third-party) → app disappears from the picker, appears in
   the tracked list; `SBIconVisibility` is absent in Show Hidden Icons.
6. **Unhide** → entry disappears; preference still absent (default).
7. **Reset Home Screen Layout** → both plists gone (check with Files), respring
   rebuilds a default layout; restore the `pre-reset` backup to get the old
   layout back, then respring.
8. Restore a backup that contains `applicationState.db`, then reboot and check
   that SpringBoard is healthy.
