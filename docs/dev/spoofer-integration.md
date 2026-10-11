# Device & Status Spoofer — integration notes

Two-section spoofing screen for Lara:

1. **Fake status bar** — battery percentage/charging, Wi-Fi bars, cellular bars,
   carrier text and a fake clock, applied live in SpringBoard through the
   existing RemoteCall primitive (`mgr.sbProc`), plus backup/restore/remove of
   SpringBoard's own status bar override archive.
2. **iOS version spoof** — read/write `BuildVersion` / `ProductVersion` in the
   MobileGestalt cache (`CacheExtra`), with a timestamped safety backup,
   revert and full-restore.

Target: iOS 26.0 (23A341) SpringBoard / libMobileGestalt symbols, as verified
by the reverse-engineering pass behind this feature. Nothing existing is
modified; the files below are new and the Xcode file-system synchronized group
rooted at `lara/lara/` picks them up automatically.

- View: `lara/lara/views/tweaks/spoofer/StatusBarFakesView.swift`
- MobileGestalt helpers: `lara/lara/funcs/mgspoof.swift`
- Reference patterns: `lara/lara/views/tweaks/StatusBarStudioView.swift`,
  `lara/lara/kexploit/pe/rc.m` → `status_bar_time_format()` (lines 44–89)
- RemoteCall internals: `lara/lara/kexploit/TaskRop/RemoteCall.{h,m}`
- MG editor reference: `lara/lara/views/tweaks/mobilegestalt/GestaltView.swift`

---

## 1. Fake status bar — how it calls SpringBoard

`StatusBarFakesView` receives the same `mgr: laramgr` as every other RC screen
and uses `mgr.sbProc`, the `RemoteCall` instance bound to SpringBoard by
"Initialize RemoteCall".

All remote ObjC calls are made **from Swift** with the C bridge helpers
declared in `RemoteCall.h` (imported into Swift by `lara-Bridging-Header.h`),
exactly like `StatusBarStudioView`:

| Helper | Used for |
| --- | --- |
| `remote_getClass(proc, name)` | class lookup (`UIApplication`, archiver, record, SystemStatus classes) |
| `remote_sel(proc, name)` | selector registration |
| `remote_msg(proc, obj, sel, a0…a3)` | `objc_msgSend` in SpringBoard (up to 4 args, x0–x3) |
| `remote_NSString(proc, "text")` | remote `NSString` argument (ASCII, proven path) |
| `remote_alloc_str(proc, "text")` | remote C string (non-ASCII fallback) |
| `proc.remoteRead(_:to:size:)` | reading strings/paths back out of SpringBoard |

Every private selector is gated with `respondsToSelector:` before it is sent;
an unrecognized selector would raise inside SpringBoard, which is the main
crash risk of this feature.

### Call shape

1. Resolve targets fresh on every action (never cache pointers):
   - `[[UIApplication sharedApplication] statusBarStateAggregator]` — proven
     lookup from `rc.m`.
   - `SBSystemStatusStatusBarOverridesArchiver` singleton, via the class
     `sharedInstance` class method when it responds. A **fresh instance is
     never allocated** for the archiver: it owns observers and a second
     instance could double-write the archive file.
   - `-_queue_readStatusBarOverridesArchiveRecord` on the archiver returns the
     persisted `_SBSystemStatusStatusBarOverridesArchiveRecord` (may be 0).
   - `[STMutableStatusBarOverridesStatusDomainData new]` and, during persist,
     `[STStatusBarOverridesStatusDomainPublisher new]`.
   - `[[UIApplication sharedApplication] delegate]` — inside SpringBoard this
     is the SpringBoard app-delegate object that carries
     `_sbApplySystemStatusStatusBarOverridesArchiveRecord:`.
2. Each value is sent to the first target that implements the setter, in
   priority order: **archiveRecord → archiver → aggregator → domainData**.
   Values are passed as `NSNumber` (`numberWithInt:` / `numberWithBool:`) or
   `NSString`; missing selectors are logged and skipped.
3. Persist step (each call independently gated):
   - `-_queue_persistUpdatedArchiveRecord:` (record) — only when a record was
     read from the archiver, or a freshly created record actually received at
     least one value.
   - `-_queue_writeOutArchiveRecord:` (record).
   - `-_queue_setupObservingAndReconcileInitialState` (zero args).
   - `_sbApplySystemStatusStatusBarOverridesArchiveRecord:` (record) on the
     SpringBoard delegate.
   - `updateData:` (domain data) on a fresh
     `STStatusBarOverridesStatusDomainPublisher`.
4. The status bar is refreshed through
   `performSelectorOnMainThread:withObject:waitUntilDone:` with
   `_updateBatteryItems`, `_updateOverrideDate`, `_updateTimeItems`,
   `_updatePersonNameItem`, `_updateDataNetworkItem` (whichever exist), same
   as `rc.m` / Status Bar Studio.

Apply offers a respring alert; Clear sends `nil`/`0` values (empty string for
carrier) through the same targets and persists the empty state.

### Selector / symbol inventory

| Symbol | Sent to | Status | Notes |
| --- | --- | --- | --- |
| `_archiveFileURL` (class method) | `SBSystemStatusStatusBarOverridesArchiver` | **Verified (iOS 26.0)** | discovers the archive file path; NSURL → `path` → `UTF8String` |
| `_queue_readStatusBarOverridesArchiveRecord` | archiver instance | **Verified (iOS 26.0)** | returns the current record |
| `_queue_persistUpdatedArchiveRecord:` | archiver instance | **Verified (iOS 26.0)** | one record arg |
| `_queue_writeOutArchiveRecord:` | archiver instance | **Verified (iOS 26.0)** | one record arg |
| `_queue_setupObservingAndReconcileInitialState` | archiver instance | **Verified (iOS 26.0)** | zero args |
| `supportsSecureCoding` (class method) | `_SBSystemStatusStatusBarOverridesArchiveRecord` | **Verified (iOS 26.0)** | probed by "Discover" |
| `_sbApplySystemStatusStatusBarOverridesArchiveRecord:` | SpringBoard app delegate | **Verified (iOS 26.0)** | one record arg |
| `STMutableStatusBarOverridesStatusDomainData` | class | **Verified name (iOS 26.0)** | created with `new` |
| `STStatusBarOverridesStatusDomainPublisher` | class | **Verified name (iOS 26.0)** | created with `new`; `updateData:` is the best-effort publish call |
| `setBatteryPercentage:` | any of the four targets | best-effort | selector name given by the verification pass, **class context unknown**; NSNumber arg |
| `setCarrierName:` | any of the four targets | best-effort | same; NSString arg; `setUserNameOverride:` is intentionally not duplicated (Status Bar Studio covers it) |
| `setOverrideTime:` | any of the four targets | best-effort | NSString arg |
| `advanceOverrideDateByAmount:` | — | **not called** | takes a scalar double; `remote_msg` only passes x0–x3, so a double would land in the wrong register. Documented, not sent. |
| `setBatteryCharging:` / `setCharging:` / `setBatteryIsCharging:` / `setIsCharging:` | any target | guess | charging has no verified setter; all candidates are `respondsToSelector:`-gated |
| `setWifiBars:` / `setWiFiBars:` | any target | guess | Wi-Fi/cellular bars have no verified setter at all |
| `setCellularBars:` | any target | guess | same |
| `_updateBatteryItems` / `_updateOverrideDate` / `_updateTimeItems` / `_updatePersonNameItem` / `_updateDataNetworkItem` | `SBStatusBarStateAggregator` | known from iOS 26 strings / rc.m | refresh only, dispatched on SpringBoard main thread |
| `sharedInstance` | archiver class | guess | singleton access; when absent the archiver is simply not a target |

Failure strings contain `-> failed` so the alert path copied from
`RemoteView`/`StatusBarStudioView` (`isFailure`) fires.

### Override archive

`+[SBSystemStatusStatusBarOverridesArchiver _archiveFileURL]` is called by the
**Discover** button and also on every Apply/Clear. When the file exists it is
copied to `Documents/lara_backups/statusbaroverrides-<timestamp>.archive`
before the persist calls are made. The screen exposes:

- **Backup override archive** — manual copy of the discovered file.
- **Restore archive from session backup** — `mgr.lara_overwritefile(target:
  source:)` puts the session copy back (needs the sandbox escape).
- **Remove override archive file** (confirmed via alert) — deletes the file,
  or truncates it to 0 bytes through the sbx write path when deletion fails.
  SpringBoard treats an empty/invalid record as a reset and evicts the file
  itself (matches public iOS 27 research on the same class; see §6).

The archive format on iOS 26 was not dumped by this feature. Public research
on iOS 27 describes `/var/mobile/Library/SpringBoard/StatusBarOverrides.archive`
as an `NSKeyedArchiver` binary plist with root class
`_SBSystemStatusStatusBarOverridesArchiveRecord` and a nested `STStatusBarData`
(`cellularEntry` / `secondaryCellularEntry`). This screen does not parse or
rewrite that format; it only backs it up, restores it or removes it, and lets
SpringBoard do the reading/writing.

### Volatility warning shown in the UI

- Overrides are applied live through RemoteCall and are volatile: a respring or
  SpringBoard restart can drop them. If the archive was successfully persisted
  they may come back; otherwise re-apply.
- RemoteCall hijacks a live SpringBoard thread and is unstable; worst case is a
  wedged/crashed SpringBoard that needs a respring (or reboot).

---

## 2. iOS version spoof (MobileGestalt)

Implemented in `lara/lara/funcs/mgspoof.swift`; the view only wires the UI.

### Key mapping

The MobileGestalt cache (`mgCurrentPath`, defined in `GestaltView.swift`) is a
binary plist whose `CacheExtra` dictionary is keyed by obfuscated ("symbolic")
keys. The readable names only exist inside `libMobileGestalt.dylib`. The
built-in table comes from the public deobfuscation mapping
(PoomSmart/MGKeys `mapping-gestalt.h`, The Apple Wiki "List of MobileGestalt
keys"); every entry is still marked current there and the readable strings
were verified in the iOS 26.0 dylib:

| Readable key | Symbolic CacheExtra key | Write |
| --- | --- | --- |
| `BuildVersion` | `mZfUC7qo4pURNhyMHZ62RQ` | yes |
| `ProductVersion` | `qNNddlUK+B/YlooNoymwgA` | yes |
| `OSVersion` | alias of `ProductVersion` (no separate slot) | no (read-only alias) |
| `BuildID` | `qwXfFvH5jPXPxrny0XuGtQ` | no (display only) |
| `ReleaseType` | `9UCjT7Qfi4xLVvPAKIzTCQ` | no (display only) |
| `DeviceClass` | `+3Uf0Pm5F8Xy7Onyvko0vA` | no (display only) |
| `ProductType` | `h9jDsbgj7xIVeIQ8S3/X3Q` | no (display only) |

Lookup order per key: literal readable key in `CacheExtra` → alias → table.
If none maps, the key is reported as **read-only** in the UI and Apply is
disabled. Reads additionally fall back to the `CacheData` blob when it happens
to parse as a plist (best-effort).

### Read / write flow

- **Read** (`mgspoofreadvalues`): direct plist read first (works once the
  sandbox escape is active), VFS read as fallback. The UI shows
  `BuildVersion`, `ProductVersion`, `OSVersion (alias)`, `BuildID`,
  `ReleaseType`, `DeviceClass`, `ProductType`, plus "device truth" from
  `sysctlbyname("kern.osversion")` and `ProcessInfo` for contrast.
- **Validate**: BuildVersion `^[0-9]{2}[A-Za-z][0-9A-Za-z]{2,5}$`
  (e.g. `23A341`), ProductVersion `^[0-9]{1,2}(\.[0-9]{1,2}){1,2}$`
  (e.g. `26.0`, `26.0.1`). Invalid input disables Apply and is shown inline.
- **Backup**: every Apply writes a timestamped copy of the whole cache to
  `Documents/lara_backups/mgspoof-MobileGestalt-<timestamp>.plist`. Without a
  successful backup the write is refused.
- **Apply** (`mgspoofapply`): requires `mgr.sbxready`; loads the cache with
  `loadMutablePlistDictionary` (from `GestaltView.swift`), sets
  `CacheExtra[BuildVersion]` / `CacheExtra[ProductVersion]`, validates and
  serializes with a quiet local `mgspoofserializecache` (same checks as
  `verifyPlist`, but no UI alerts because this runs off-main), then writes via
  `mgr.lara_overwritefile(target:data:fallback_vfs: false)` — the same path
  `GestaltView.applyGestalt()` uses.
- **Revert** (`mgspoofrevert`): removes the two symbolic keys from `CacheExtra`
  and writes the cache back, so `MGCopyAnswer` falls back to the underlying
  system values.
- **Restore backup** (`mgspoofrestorebackup`): overwrites the whole cache with
  the newest mgspoof backup (also undoes other MG edits made after it).

The UI offers a respring after Apply/Revert/Restore.

### Warnings shown in the UI

- Version spoofing can break system components that trust these values:
  OTA/update checks, App Store/eligibility flows, Settings > General > About
  mismatches, other version-gated behavior.
- Tools that read `kern.osversion` (sysctl) or the sealed
  `/System/Library/CoreServices/SystemVersion.plist` are **not** affected and
  still see the real version. Only components going through `MGCopyAnswer` see
  the spoof.
- Every write is backed up first; revert removes the spoofed keys; restore
  rolls the whole cache back.

---

## 3. Risks

1. **RemoteCall is unstable.** It hijacks a live SpringBoard thread. Worst
   case is a wedged/crashed SpringBoard; recovery is a respring/reboot.
2. **Unrecognized selector = SpringBoard crash.** Mitigated by
   `respondsToSelector:` gating for every private selector, including all
   guessed setters and `sharedInstance`.
3. **Wrong argument shape.** Numeric setters are assumed to take `NSNumber`
   objects (the record/domain-data classes are NSCoding value objects). If a
   setter is scalar, an object pointer is read as a number (wrong value, no
   crash); if a setter is object-typed and a raw number were passed, it would
   crash — that is why numbers are always objects here.
4. **Freshly created records.** When no record exists, a new
   `_SBSystemStatusStatusBarOverridesArchiveRecord` is allocated as a carrier
   and only persisted if at least one value landed on it. Its coder path is
   not verified on iOS 26; if persistence misbehaves, Clear/Remove restores a
   clean state.
5. **Overrides are volatile.** Live state lives in SpringBoard memory; the
   archive is the persistence layer. Respring/SpringBoard restarts may drop
   live-only changes.
6. **MG writes are read-modify-write.** A crash between read and write cannot
   corrupt the file (the new plist is fully validated before writing, and a
   backup exists), but concurrent editors (e.g. GestaltView) can race.
7. **Version spoofing is not sandbox-safe behavior.** It is an experimental
   feature; the backup/revert path is the escape hatch.
8. **Shared RemoteCall thread state.** Do not run this screen concurrently with
   another RC action (RemoteView buttons, JIT, etc.). The app has no global RC
   lock; concurrent `remote_msg` calls can corrupt the hijacked thread state.
9. **Remote string leak (bounded).** The ASCII `NSString` path uses the proven
   `remote_NSString` (frees its own C buffer). The non-ASCII fallback and the
   remote `NSNumber`s are intentionally leaked: no remote `free()` helper is
   exposed to Swift. A few bytes per Apply.

---

## 4. Integration snippet (TweaksView.swift)

Preferred: in the existing **User Interface** section, right after the
`MobileGestalt` entry (`TweaksView.swift` around line 49):

```swift
NavigationLink("Device & Status Spoofer", destination: StatusBarFakesView(mgr: mgr))
```

Alternative: a dedicated section (TweaksView's List is already disabled until
`mgr.dsready`, and the screen handles both not-ready states itself, so no extra
gate is required):

```swift
Section(header: HeaderLabel(text: "Spoofing", icon: "theatermasks")) {
    NavigationLink("Device & Status Spoofer", destination: StatusBarFakesView(mgr: mgr))
}
```

Optional stricter gate when you want the entry greyed out until at least one
escape is available:

```swift
NavigationLink("Device & Status Spoofer", destination: StatusBarFakesView(mgr: mgr))
    .disabled(!mgr.sbxready && !mgr.rcready)
```

`TweaksView` already has a `NavigationStack`, so the `NavigationLink` works
as-is.

---

## 5. Testing checklist

1. Exploit → *Initialize RemoteCall* (SpringBoard) → Status shows Ready.
2. Tweaks → Device & Status Spoofer → *Discover override archive path*:
   expect a path and `record class ok (supportsSecureCoding=…)`.
3. *Apply fake overrides* with battery 88 %, Wi-Fi 2, cellular 3, carrier
   `lara`, time `09:41`. Check the Last Result line: which values landed on
   which target, which selectors were missing, which persist calls ran.
4. Confirm the visible status bar changes where supported; missing selectors
   must be reported, never crash.
5. *Backup override archive* → check `Documents/lara_backups/`; *Restore* and
   *Remove* must not touch anything else.
6. *Clear all overrides* → values revert (or are re-read from the removed
   archive after a respring).
7. Respring → overrides may be gone; re-apply to confirm recovery.
8. Version spoof: read current values; Apply `23A341` / `26.0`; confirm the
   backup file appears and Last Result reports the symbolic keys written.
9. Reopen the screen → current values show the spoofed ones; "device truth"
   still shows the real build.
10. *Revert (remove spoofed keys)* → values fall back; *Restore MG cache from
    latest backup* also works.
11. While an action runs, buttons are disabled and no other RC screen is used
    simultaneously.

---

## 6. Verified vs best-effort summary

**Verified in iOS 26.0 SpringBoard (from the reverse-engineering pass):**

- `SBSystemStatusStatusBarOverridesArchiver` and its `+_archiveFileURL`,
  `-_queue_persistUpdatedArchiveRecord:`, `-_queue_writeOutArchiveRecord:`,
  `-_queue_readStatusBarOverridesArchiveRecord`,
  `-_queue_setupObservingAndReconcileInitialState`.
- `+[_SBSystemStatusStatusBarOverridesArchiveRecord supportsSecureCoding]`.
- `_sbApplySystemStatusStatusBarOverridesArchiveRecord:` on SpringBoard.
- SystemStatus class names `STStatusBarOverridesStatusDomainData` /
  `STMutableStatusBarOverridesStatusDomainData` /
  `STStatusBarOverridesStatusDomainPublisher`.
- Selector names `setOverrideTime:`, `advanceOverrideDateByAmount:`,
  `_updateOverrideDate`, `setBatteryPercentage:`, `setCarrierName:` (class
  context unknown).
- Readable MG strings `BuildVersion`, `ProductVersion`, `OSVersion`, `BuildID`,
  `ReleaseType`, `DeviceClass`, `ProductType` in libMobileGestalt.dylib 26.0.

**Best-effort (not device-verified by this feature):**

- Archiver singleton via `sharedInstance` (fallback: not a target).
- `updateData:` as the publisher call name.
- All numeric/charging/Wi-Fi/cellular setter candidates.
- Passing `NSNumber` objects for numeric setters.
- `new` on the record/domain-data/publisher classes.
- Reading `_archiveFileURL` → `path`/`absoluteString` (NSURL fallback).
- The iOS 26 archive path and format (path is discovered at runtime; format is
  not parsed).
- MG symbolic key table (public deobfuscation tables; not re-derived from the
  iOS 26.0 binary in this pass).
- The effect of writing these MG keys on iOS 26 (read-modify-write mechanics
  are the same as GestaltView's, which works for other keys).

**Uncertainties / TODO:**

- Exact property types and names on the record/domain data (scalar vs object).
  Runtime `method_getTypeEncoding` probing would settle this; not implemented
  because it needs more remote-call plumbing.
- Whether `setOverrideTime:` takes an `NSString` or an `NSDate`. The NSString
  form is sent (mirrors the proven string setter pattern); if it turns out to
  be `NSDate`, the call is type-safe at the objc_msgSend level but the value
  will not parse as a date.
- `advanceOverrideDateByAmount:` is intentionally not called (double arg).
- Whether SpringBoard re-reads the archive after `_queue_writeOutArchiveRecord:`
  or needs the respring offered by the alerts.
- `_archiveFileURL` on iOS 26 may point at the legacy `statusBarOverrides`
  struct instead of the iOS 27 `StatusBarOverrides.archive`; the feature
  treats whatever URL it returns as opaque and only backs up/removes it.
- Version-spoof `CacheExtra` removal is treated as revert; if a cache already
  contained the original values, removal falls back to the computed values
  instead of restoring the old bytes (full restore is available via backup).
- `mgspoof.swift` depends on `mgCurrentPath` and
  `loadMutablePlistDictionary(from:)` from `GestaltView.swift` (both internal
  globals in the same target).
