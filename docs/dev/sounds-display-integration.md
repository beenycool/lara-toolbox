# Sounds & Display (Lab) — integration notes

Two small Lab features implemented in one view:

- View: `lara/views/tweaks/lab/SoundsAndDisplayView.swift`
- Both features are "apply now, revert on reboot" tweaks that ride on the existing exploit primitives.

The file sits inside the `lara` folder that is a file-system synchronized group in
`lara.xcodeproj`, so it is picked up automatically by the build. **No `.xcodeproj` change is
needed** (and none was made).

## TweaksView entry

A "Lab" section with this entry was added to `lara/views/tweaks/TweaksView.swift` by the
integration pass (already wired; compiles in CI):

```swift
Section(header: HeaderLabel(text: "Lab", icon: "flask")) {
    NavigationLink("Sounds & Display (Lab)", destination: SoundsAndDisplayView(mgr: mgr))
        .disabled(!mgr.vfsready && !mgr.sbxready)
}
```

The entry is enabled when *either* backend is ready because the view contains two features with
different requirements (see gating below). `TweaksView` is already globally disabled until
`mgr.dsready`, so no extra `dsready` check is required.

## Gating (inside the view)

| Feature | Requires | Reason |
|---|---|---|
| Custom System Sounds (replace/backup) | `mgr.vfsready` | Uses `vfsoverwritefromlocalpath` / `vfsread` / `vfssize`, exactly like `FontPicker.swift` |
| Night Shift apply/reset | `mgr.sbxready` | Uses `setplistvalue`, which prefers the sandbox-escape `open()` path (managed prefs live in `/var`, not SSV) |

When the backend is missing, buttons are disabled and a status row explains why; every action also
re-checks the flag and logs the abort.

## Feature A — Custom System Sounds

### Targets

The target list reuses the exact paths from
`views/tweaks/dirtyZero/dirtyZeroTweakArray.swift` → `ZeroSection "Sound Effects"`:

- `/System/Library/Audio/UISounds/Modern/airdrop_invite.cat`
- `/System/Library/Audio/UISounds/connect_power.caf`
- `/System/Library/Audio/UISounds/low_power.caf`
- `/System/Library/Audio/UISounds/payment_success.caf`
- `/System/Library/Audio/UISounds/payment_failure.caf`
- `/System/Library/Audio/UISounds/nano/dtmf-0..9.caf`, `dtmf-star.caf`, `dtmf-pound.caf`

### Size cap (important)

The overwrite path cannot grow a file: replacement bytes must be **≤ the original file size**, and
the leftover tail is zeroed. The view enforces this before writing:

1. Reads the original size (`vfssize` first, then `FileManager.attributesOfItem` as a fallback).
2. Reads the imported file size.
3. Refuses when `replacement > original` with a visible error row plus an alert that recommends
   converting to a smaller `.caf` (shorter duration / lower sample rate).

Sizes are shown per target row; "Refresh Sizes" re-reads them (e.g. after VFS becomes ready).

### Import

`.fileImporter` with `UTType(filenameExtension: "caf")` and `"aiff"` (falls back to `.audio` if
the system returns nil UTIs). Imported files are copied into `Documents/LabSounds/` with
security-scoped access handled. Extensions other than `caf`/`aiff`/`aif` are rejected in code as
well, not just by the picker filter.

### Backup

"Back Up Original Sound" reads the current bytes with `mgr.vfsread(path:maxSize:)` and writes them
to `Documents/UISoundsBackup/<filename>`. `UIFileSharingEnabled` is set in `Info.plist`, so those
files are visible in the Files app and can be re-imported through the picker.

### Revert semantics

The write goes through the in-memory VFS overwrite (`vfsoverwritefromlocalpath`, same call
`FontPicker` uses), so the change **reverts on reboot**. A respring is suggested to make the new
sound take effect (audioserver caches sounds).

### Caveats

- `airdrop_invite.cat` is a `.cat` container; substituting plain CAF bytes may not work there.
- Format validity is not checked (no CAF/AIFF header validation) — only extension and size. The
  bytes are written verbatim.

## Feature B — Night Shift boost

### Target plist

`/var/Managed Preferences/mobile/com.apple.CoreBrightness.plist`

### Keys written

| Key | Type | Value written |
|---|---|---|
| `BlueLightReductionEnabled` | bool | toggle state |
| `BlueLightReductionCCTTargetRaw` | number | CCT slider, 2700–6500 (written as `Int`) |
| `BlueLightReductionFactorValue` | number | strength 0–100 % mapped to `0.0–1.0` (`Double`) |
| `BlueLightReductionMode` | number | `1` when enabled, key removed when disabled |

Apply writes all keys via `mgr.setplistvalue(path:key:force:)` (the `GestaltView` pattern) and
then shows an alert whose action is `mgr.respring()`. Reset removes all four keys instead of
restoring prior values.

If `com.apple.CoreBrightness.plist` does not exist, apply and reset refuse to run (so the app never
creates an empty managed-prefs file).

### Why a respring, and what it means

`mgr.respring()` sets `showrespring`, which overlays the JS-based `respringview` from
`views/other/respring.swift` (see `lara.swift`). That reloads SpringBoard, not `corebrightnessd`
itself. The footer tells the user that a **reboot** is the only full reload if a respring has no
effect.

## Uncertainties / follow-ups

1. **`BlueLightReductionFactorValue` scale** — the code assumes `0.0–1.0`. If CoreBrightness
   expects `0–100`, the strength will be wrong. Load code heuristically treats a stored value
   `> 1.0` as a percentage, but apply always writes `0.0–1.0`. Verify on-device and adjust the
   mapping in `applynightshift()`.
2. **`BlueLightReductionMode` semantics** — documented as "1 = sunset-to-sunrise?" but unconfirmed.
   It is written as `1` when enabled and removed when disabled. If mode 1 turns out to mean a
   scheduled mode that overrides the CCT target, drop the write.
3. **`BlueLightReductionCCTTargetRaw` integer vs real** — written as `Int`. If the daemon wants a
   float, switch to `nscct` (Double).
4. **Respring sufficiency** — CoreBrightness may only re-read the plist at boot or on
   backboardd/daemon restart. If respring does nothing, a daemon kill or reboot is needed; this is
   called out in the UI footer.
5. **Reset is not a snapshot restore** — removing keys restores defaults, but if the stock plist
   already contained non-default values for these keys, they are lost. A "back up plist first"
   step was intentionally left out of this first pass.
6. **`.cat` target** — no verification that a `.caf` payload works inside `airdrop_invite.cat`.
7. **VFS size vs real size** — `vfssize` reads the live VFS view; if VFS is stale the validation
   could be off. Refresh Sizes before replacing when in doubt.

## Manual verification checklist (on device)

1. Run the exploit → VFS ready. Open Sounds & Display; confirm sizes appear for 17 targets.
2. Import a small `.caf` (< original size) and replace e.g. `connect_power.caf`; plug in power and
   confirm the new sound (respring if not).
3. Import a file larger than the target; confirm the refusal alert and that no write is attempted
   (check the log).
4. Back up a target; confirm the file appears in `Documents/UISoundsBackup`.
5. With sandbox escape ready, apply Night Shift (e.g. 3000 K, 80 %); respring; check
   `com.apple.CoreBrightness.plist` keys; then Reset to Stock and confirm the keys are gone.
6. Reboot and confirm sound changes are gone (SSV in-memory revert).
