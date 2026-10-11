# Global UI Preferences — integration notes

Status: files delivered and CI-compiled (macos-26, commit `1878307`). The authoring agent stalled
before writing this doc; it was reconstructed from the delivered code by the integration pass.

## Files

| File | Role |
|---|---|
| `lara/funcs/uiprefs.swift` | Managed-preference helpers: read/write/backup/restore, `com.apple.darkmode.changed` post |
| `lara/views/tweaks/uilab/GlobalPrefsView.swift` | UI (7 sections, per-section restore, footer docs) |

## Integration (already applied)

`TweaksView.swift` → **User Interface** section:

```swift
NavigationLink("Global UI Preferences", destination: GlobalPrefsView(mgr: mgr))
    .disabled(!mgr.sbxready)
```

No bridging-header import needed (pure Swift). No `.xcodeproj` change (sync group).

## Preference surface

All writes target `/var/Managed Preferences/mobile/`:

| Domain plist | Keys | Notes |
|---|---|---|
| `com.apple.UIKit.plist` | `UIUserInterfaceStyle` (0 auto / 1 light / 2 dark), `UIAnimationDragCoefficient` (float, 1.0 default) | posts `com.apple.darkmode.changed` after style writes |
| `com.apple.Accessibility.plist` | `ReduceMotionEnabled`, `ReduceTransparencyEnabled`, `IncreaseContrastEnabled` | |
| `com.apple.SystemStatusUI.plist` | `batteryPercentageAlwaysEnabled`, `batteryCondensedPercentageForceEnabled` | |
| `com.apple.Preferences.plist` | `KeyboardAutocorrection`, `KeyboardPrediction`, `KeyboardAutocapitalization`, `KeyboardShowPredictionBar` | **unverified on iOS 26** — marked in the UI |

## Safety behavior

- Every write is backed up once to `Documents/lara_backups/<sanitized-path>`; existing backups are
  never overwritten (earliest known state stays recoverable).
- `uiprefswritable()` = `mgr.sbxready || mgr.vfsready`; reads fall back to `vfsread` when direct
  reads are denied.
- Per-section "Restore Defaults" removes the managed keys (and re-posts the dark-mode notification
  for the style section). The code deliberately refuses to create a missing plist on restore.
- All actions log via `globallogger`.

## Open questions (device-testing checklist)

1. **Keyboard key names** are assumed (classic raw keys); confirm with `plutil -p` on a live device
   before trusting that section.
2. **cfprefsd caching** — a direct plist write may be ignored or overwritten by the preferences
   daemon; if respring is insufficient, next step is killing `cfprefsd` (or reboot).
3. **Respring** is required to apply; the UI footers state this.
4. `UIAnimationDragCoefficient` semantics (0.5 faster / 2.0 slower) are conventional, not verified
   on 26.0.
5. Managed-preferences vs `/var/mobile/Library/Preferences` precedence should be confirmed once on
   device (the MG editor already writes the same managed path successfully, which is why it was
   chosen here).
