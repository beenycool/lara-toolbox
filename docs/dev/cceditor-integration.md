# Control Center Layout Editor — integration notes

Feature: **Control Center Layout Editor** (`CCEditorView`), a replacement for the old,
non-functional dirtyZero "Control Center" section.

Status: **code complete, not yet validated on-device.** The exact preference path and
schema for the iOS 26.0 Control Center module layout are unconfirmed. The view is
deliberately built as a *probe-and-log* tool: it probes every candidate location,
adapts to whichever file/nesting it finds, and shows the results in the UI so they
can be reported back and the feature can be finalized.

## Files

| File | Purpose |
| --- | --- |
| `lara/views/tweaks/cc/CCEditorView.swift` | The editor view (UI + all logic). |
| `docs/dev/cceditor-integration.md` | This document. |

> Note: the working repo root is `.../apple_carplay/lara`; the Xcode synchronized
> source group is the nested `lara/` folder. The Swift file therefore lives at
> `.../apple_carplay/lara/lara/views/tweaks/cc/CCEditorView.swift`, which is what
> the file-system-synchronized group picks up automatically. No `.xcodeproj`
> changes are needed.

## Integration into `TweaksView.swift`

The view takes the shared manager directly (`CCEditorView(mgr: mgr)`), matching
`ShowHiddenIconsView` / `GestaltView`. Gate it on `mgr.sbxready` because all reads
and writes use the sandbox escape.

Suggested placement (the existing "User Interface" section is a good fit):

```swift
Section(header: HeaderLabel(text: "User Interface", icon: "eye")) {
    NavigationLink("dirtyZero", destination: dirtyZeroView())
        .disabled(!mgr.vfsready)
    NavigationLink("Show Hidden Icons", destination: ShowHiddenIconsView(mgr: mgr))
        .disabled(!mgr.sbxready && !mgr.vfsready)
    NavigationLink("MobileGestalt", destination: GestaltView(mgr: mgr))
        .disabled(!mgr.sbxready)
    // NEW:
    NavigationLink("Control Center Layout", destination: CCEditorView(mgr: mgr))
        .disabled(!mgr.sbxready)
    NavigationLink("Font Overwrite", destination: FontPicker(mgr: mgr))
        .disabled(!mgr.vfsready)
    NavigationLink("SystemColor Patcher", destination: SystemColor(mgr: mgr))
        .disabled(!mgr.sbxready || !mgr.vfsready)
}
```

Optionally the broken `CCView` placeholder under `views/tweaks/broken/` can be
deleted once this feature is validated (it is not wired into `TweaksView` today).

## What the view does

### 1. Probing

On appear (and whenever `mgr.sbxready` flips to true, and on demand) the view probes
**all** of these, logging every probe with the `(cc)` prefix via `globallogger.log`:

- `/var/mobile/Library/Preferences/com.apple.ControlCenter.plist` (candidate a)
- `/var/mobile/Library/Preferences/com.apple.ControlCenterSettings.plist` (candidate b)
- `/var/mobile/Library/ControlCenter/ModuleConfiguration.plist` (extra guess)
- `/var/Managed Preferences/mobile/com.apple.ControlCenter.plist` (extra guess)
- `/var/mobile/Library/Preferences/com.apple.ControlCenterUI.plist` (extra guess)
- Every bundle in `mgr.getAppList()` whose bundle id / executable / display name /
  bundle name contains `controlcenter`, `control-centre`, `control center`, etc.
  (candidate c). For those containers it probes:
  - `Data/Application/<dataFolder>/Library/Preferences/ModuleConfiguration.plist`
  - `Data/Application/<dataFolder>/Library/Preferences/<bundle-id>.plist`
  - `Data/Application/<dataFolder>/Library/Preferences/com.apple.ControlCenter.plist`
  - `Data/Application/<dataFolder>/Library/ControlCenter/ModuleConfiguration.plist`
  - any `*.plist` in the container's `Library/Preferences` whose name contains
    `control` or `module`
  - `Bundle/Application/<bundleFolder>/ModuleConfiguration.plist` and
    `<App>.app/ModuleConfiguration.plist`

Each probe result shows in the UI: path, exists/readable, where the managed keys
were found (top-level or nested, e.g. `Root > Sub > key`), how many modules were
found, and any read error. A checkmark marks the file currently being edited.

### 2. Editing

- **Load**: the first readable candidate that contains
  `orderedUserEnabledModuleIdentifiers` wins; otherwise the first readable
  candidate. The user can tap any readable source to switch.
- **Add**: from the known-module catalog or by typing a custom identifier.
- **Remove**: removes from the enabled array and appends to
  `userDisabledModuleIdentifiers` (mirroring how iOS marks user-disabled modules).
- **Re-enable**: moves an entry from the disabled array back into the enabled array.
- **Reorder**: up/down buttons, order written to
  `orderedUserEnabledModuleIdentifiers`.
- Keys are located **recursively** and updated in place if nested; if a key is not
  present it is created at the top level of the selected plist. This is the
  defensive part of the probe-and-log design.

Known module identifiers offered (first six verified for iOS 26.0):

```
com.apple.control-center.MuteModule
com.apple.control-center.FlashlightModule
com.apple.control-center.QrCodeModule
com.apple.control-center.OrientationLockModule
com.apple.control-center.LowPowerModule
com.apple.control-center.ScreenMirroring
```

Accessibility modules are offered with **and** without the
`com.apple.control-center.` prefix (the exact form is unconfirmed):
`HearingAidsModule`, `MagnifierModule`, `ShazamModule`,
`AccessibilityMotionCuesControlCenterModule`.

### 3. Backups

Before **every** write (apply or reset), the current file is copied to:

```
Documents/lara_backups/cceditor/
    orig-<sanitized-path>                  # first-seen original, kept forever
    snapshot-<yyyyMMdd-HHmmss>-<path>.plist # taken before every write
```

### 4. Reset to Defaults

- If `orig-<sanitized-path>` exists → restore it.
- Otherwise → remove `orderedUserEnabledModuleIdentifiers` and
  `userDisabledModuleIdentifiers` wherever they are found and write the file back.
- A backup snapshot is taken before the reset write as well.

### 5. Apply / respring

Applying writes the plist through `mgr.lara_overwritefile(target:data:)` (same
SBX/VFS path used by `mgr.setplistvalue`), validates the serialized plist with the
existing global `verifyPlist` helper, then shows an `Alertinator` alert whose
**Respring** button calls `mgr.respring()` — the exact mechanism used by
`GestaltView`, `SpringBoardView`, `dirtyZeroView`, etc. `killproc` from `utils.h`
is intentionally not used; the repo's respring helper is the established path.

If no candidate exists, the Actions section offers
**"Use standard plist (create if missing)"**, which targets
`/var/mobile/Library/Preferences/com.apple.ControlCenter.plist` and creates it on
apply. This is explicit opt-in because it may be the wrong location.

## On-device test checklist

1. Run the exploit, initialize the sandbox escape (`mgr.sbxready == true`).
2. Open Tweaks → Control Center Layout. Wait for "probe finished" in the Status
   section.
3. Note which candidate(s) report `exists`/`readable`, and which one contains
   `orderedUserEnabledModuleIdentifiers`. **This is the key data point to report.**
4. Check the app log (`(cc)` lines in the Logs tab, or `Documents/lara.log`):
   every probe, read, backup, and write is logged there.
5. Edit the layout (add/remove/reorder), tap Apply Layout, then Respring.
6. Verify Control Center. If nothing changes:
   - Check whether the plist file content actually changed (File Manager tab).
   - Consider that `cfprefsd` caches preference files; a full reboot may be needed,
     and/or the daemon may rewrite the file. (See open questions.)
7. Test Reset to Defaults and confirm the file (or keys) returns to the original
   state.

## Open questions / risks

1. **Actual location/schema.** None of the candidate paths is confirmed for
   iOS 26.0. The probe UI exists precisely to answer this. The most likely
   candidates remain (a) and (b) under `/var/mobile/Library/Preferences/`, but the
   module layout may instead live in the SpringBoard preference domain or in
   `ModuleConfiguration.plist` in a container/daemon data dir.
2. **cfprefsd caching.** `cfprefsd` may serve cached values and later overwrite the
   file. If a respring is not enough, the next step would be killing `cfprefsd`
   (and possibly `SpringBoard`) or a full reboot. Not implemented yet on purpose.
3. **Key semantics.** It is assumed `orderedUserEnabledModuleIdentifiers` is the
   ordered enabled list and `userDisabledModuleIdentifiers` the explicit
   user-disabled list. On iOS 18 these keys were seen in this shape; iOS 26 may
   rename or nest them (the recursive key lookup handles nesting, not renaming).
4. **Accessibility identifier prefix.** `HearingAidsModule` etc. may need the full
   `com.apple.control-center.` prefix. Both variants are offered.
5. **Creating a missing plist.** Writing a brand-new
   `com.apple.ControlCenter.plist` may have no effect or may be ignored; it is an
   explicit opt-in fallback and fully backed up.
6. **Module validity.** Unknown identifiers in the arrays may be ignored or may
   cause odd Control Center behavior. A snapshot backup is always taken first.
7. **Multiple config layers.** The system may merge defaults, managed preferences,
   and the user plist; writing only one layer may not be sufficient.
8. **File protection/ownership.** Newly created files are written as the mobile
   user; a system daemon may expect different ownership/posix permissions.

## Reporting back

When reporting probe results, include:

- The list of candidates that were `exists`/`readable` and the one that contained
  `orderedUserEnabledModuleIdentifiers` (copy the Status/Probe rows or the `(cc)`
  log lines from `Documents/lara.log`).
- The top-level keys of that plist (logged automatically when the managed key is
  missing).
- Whether the layout changed after Apply + respring, and whether a reboot made a
  difference.
