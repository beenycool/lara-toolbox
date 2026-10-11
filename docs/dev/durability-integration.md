# Sideload Durability Pack — integration notes

Status: **not yet integrated**. The files below exist on disk but are not yet
reachable from Swift. One bridging-header line plus an optional navigation link
are all that is missing.

Scope: signing/provisioning state only — profile expiry, launch warnings and
the rejected/banned cdhash/UPP lists managed by MobileIdentityService (MIS).
Nothing here touches purchases, paid content or per-app license flags.

## Files added

| Requested path (repo root) | Actual path | Role |
| --- | --- | --- |
| `lara/kexploit/mis.h` | `lara/lara/kexploit/mis.h` | Public C/ObjC API |
| `lara/kexploit/mis.m` | `lara/lara/kexploit/mis.m` | Implementation |
| `lara/views/tweaks/SideloadDurabilityView.swift` | `lara/lara/views/tweaks/SideloadDurabilityView.swift` | SwiftUI UI |
| `lara/docs/dev/durability-integration.md` | `lara/docs/dev/durability-integration.md` | This document |

(The checkout nests the app sources under `lara/lara/`; the task paths were
relative to the repo root. The three source files were created next to
`ota.m`, `screentime.m` and `WhitelistView.swift`.)

## Integration steps

### 1. Bridging header (required)

`lara/lara-Bridging-Header.h` currently ends its kexploit imports with
`#import "screentime.h"`. Add exactly one line after it:

```objc
#import "screentime.h"
#import "mis.h"
```

No link settings are needed: `mis.m` reaches SQLite through
`dlopen("/usr/lib/libsqlite3.dylib")` + `dlsym`, never through a linker flag.
Do **not** add `-lsqlite3`.

### 2. Xcode target membership

The `lara` target uses a `PBXFileSystemSynchronizedRootGroup` rooted at the
`lara` folder, so `kexploit/mis.h`, `kexploit/mis.m` and
`views/tweaks/SideloadDurabilityView.swift` are picked up automatically. No
`project.pbxproj` edit is required. After opening the project, confirm `mis.m`
shows up under the `kexploit` group and is a member of the `lara` target.

### 3. Navigation entry (optional but expected)

`lara/views/tweaks/TweaksView.swift` has an "Apps" section (around the
"Unblacklist" / `WhitelistView()` link). Suggested insertion:

```swift
NavigationLink("Sideload Durability", destination: SideloadDurabilityView())
    .disabled(!mgr.sbxready)
```

`SideloadDurabilityView` takes no initializer argument; like `WhitelistView`
it observes `laramgr.shared` directly. The view also gates every action on
`mgr.sbxready` internally, so the `.disabled` is belt-and-braces.

## API surface (`mis.h`)

```objc
bool mis_backup_db(void);
NSDictionary *mis_status(void);
bool mis_extend_profiles(long long extraSeconds);
bool mis_clear_launch_warnings(void);
NSArray<NSString *> *mis_list_plists(void);
bool mis_unban_plists(void);
bool mis_restore_plists(void);
bool mis_restore_db(void);   // extra helper, see below
```

`mis_restore_db` is one function beyond the originally listed API. It exists
because the UI spec has a single "Restore Newest Backups" action and the pack
also creates `mis.db` backups — without it the database backup would be
write-only. It mirrors `mis_restore_plists` and is safe to drop if undesired.

### Behaviour details

- **Target paths** (verified against `libmis.dylib` strings; existence is
  re-checked at runtime):
  - `/private/var/db/MobileIdentityData/mis.db`
  - `Rejections.plist`, `AuthListBannedUpps.plist`,
    `AuthListBannedCdHashes.plist`, `UserOverriddenCdHashes.plist`
- **Backups** live in `Documents/lara_backups/`:
  - `mis.db.<yyyyMMdd-HHmmss>.bak`, plus `mis.db.wal.<stamp>.bak` /
    `mis.db.shm.<stamp>.bak` when the WAL side files exist.
  - `<plist name>.<stamp>.bak` for the three ban lists.
  - Same-second collisions get a `-1`, `-2`, … suffix.
- **`mis_extend_profiles`** runs `UPDATE profiles SET expires = now + extra`
  only after confirming `profiles` exists in `sqlite_master` *and* `expires`
  exists in `PRAGMA table_info(profiles)`. `extraSeconds` must be > 0.
- **`mis_clear_launch_warnings`** runs `UPDATE launch_warning SET
  user_override = 1` under the same table/column guards.
- **`mis_unban_plists`** mirrors `WhitelistView.swift`: each of the three ban
  files is overwritten with an empty XML plist (`[:]`). Unlike WhitelistView,
  it refuses to modify a file it could not back up first, and it skips files
  that do not exist. `UserOverriddenCdHashes.plist` is deliberately left alone
  because WhitelistView does not touch it either.
- **Writes** use `open(O_WRONLY|O_CREAT|O_TRUNC, 0644)` and fall back to
  `vfs_overwritefile()` (kernel VFS) when the direct write fails, matching the
  `WhitelistView` → `laramgr.vfsoverwritewithdata` pattern.
- **Diagnostics**: `mis_status()` returns the `sqlite_master` table list and
  the `PRAGMA table_info` column list for every table, plus counts and
  min/max expiry values. Missing tables/columns are reported as flags instead
  of guessed. The Swift "Diagnostics" section renders all of it.
- **Logging**: `mis.m` prints `[mis] …` lines to stdout, which
  `globallogger.capture()` already collects into `lara.log`; the Swift layer
  also mirrors each action result through `globallogger.log("(mis) …")`.

## Uncertainties / assumptions (read before trusting results)

1. **Which table the launch path consults is not fully confirmed.** The only
   schema facts taken as given are `profiles(expires)` and
   `launch_warning(user_override)`. On iOS 26 the daemon may consult a
   different table/view for "app is about to expire / launch warning" state
   (e.g. an online-auth table with `lastSuccessMonotonicTime` /
   `gracePeriod`-style columns). `mis_status()` therefore logs the *entire*
   schema; if the expected columns are absent the UI says so instead of
   writing. Do not extend the UPDATEs to other tables until the schema is
   read from a live device.
2. **`expires` units.** Assumed Unix epoch seconds. The code writes
   `time(NULL) + extraSeconds` verbatim. If the column is actually monotonic
   ticks or a CFAbsoluteTime, the value will be wrong — check the pre/post
   `minExpires`/`maxExpires` diagnostics against the known 7-day window.
3. **`user_override` semantics.** Assumed boolean-ish INTEGER where non-zero
   means "user accepted the warning". The UPDATE sets 1.
4. **Daemon caching.** `mobileidentityd`/`installd` may hold `mis.db` open and
   cache state in memory. SQLite WAL writes are visible to other connections,
   but the daemon may not re-read until restarted. Reboot (or daemon restart)
   is recommended after database changes; the UI says so.
5. **SQLite write permissions.** The UPDATE path is direct-only: a SQLite
   connection cannot be routed through the kernel VFS the way plist writes
   can. If the sandbox escape does not grant write access to
   `/private/var/db/MobileIdentityData`, `mis_extend_profiles` /
   `mis_clear_launch_warnings` return false and log the sqlite error. A
   copy → modify → VFS-push flow for the database is possible but was left out
   deliberately: byte-pushing a live WAL database invites corruption.
6. **WAL backup consistency.** `mis_backup_db` copies `mis.db`, `-wal` and
   `-shm` back to back without a checkpoint; the three copies are not an
   atomic snapshot. For a recovery backup this is acceptable, but do not treat
   it as a transactionally consistent dump.
7. **Unban = empty plist.** This is exactly what `WhitelistView.swift` does,
   including discarding any non-ban content in those files. Backups exist and
   `mis_restore_plists()` can put the previous content back.
8. **`mis_restore_db` while the daemon is running** overwrites the live
   database and then either restores matching `-wal`/`-shm` backups or unlinks
   the current side files. Reboot after use. The current state is backed up
   first as a safety net.
9. **Plists are not `chmod`ed** after rewriting; they inherit `0644` from the
   `open()` flags, same as WhitelistView.

## Manual test plan (on-device)

1. Run the kernel exploit + sandbox escape, open the view; check the
   Diagnostics section against `mis.db` reality (table names, columns,
   profile count, expiry range).
2. "Backup mis.db" → verify files in `Documents/lara_backups/` (Files app /
   `lara.log`), including `-wal`/`-shm` when present.
3. "Extend Profiles +5 Years" → status refresh should show the new min/max
   expiry (≈ now + 5 years); reboot and confirm sideloaded apps still launch
   beyond the original 7-day window.
4. "Clear Launch Warnings" → `launchWarningOverridden` should equal
   `launchWarningRows` afterwards.
5. "Unban Lists" → the three plists become empty XML, backups appear; launch
   a previously rejected app.
6. "Restore Newest Backups" → plists and `mis.db` return to the newest
   backup; a pre-restore safety copy of `mis.db` is created first.
7. Run every action once with the sandbox escape *not* ready and confirm the
   view refuses and logs instead of crashing.
