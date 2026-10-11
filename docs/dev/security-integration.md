# Kernel Security Toggles — integration notes

This document covers the "Kernel Security Toggles" lab: a global MAC enforcement
toggle (`security.mac.proc_enforce` / `mac_proc_enforce`) and a read-only AMFI
variable probe with a heavily gated single-variable write.

**This is the riskiest feature in the project. Read this whole file before wiring
it into the UI or changing the resolver.**

## Files added

| File | Purpose |
| --- | --- |
| `lara/kexploit/pe/security_ext.h` | C/ObjC API (`sec_*` functions) |
| `lara/kexploit/pe/security_ext.m` | Resolution + read/write implementation |
| `lara/views/tweaks/security/SecurityTogglesView.swift` | SwiftUI lab screen |

No existing file was modified. The bridging header import and the navigation
link are intentionally left to the integration pass.

## Integration steps

### 1. Bridging header

Add exactly this line to `lara/lara-Bridging-Header.h` (next to the other
`kexploit` imports):

```objc
#import "pe/security_ext.h"
```

Include-path style: the bridging header currently imports the `pe/` headers by
bare filename (`#import "sbx.h"`, `#import "rc.h"`), but the project's
`HEADER_SEARCH_PATHS` only contains `$(SRCROOT)/lara` and
`$(SRCROOT)/lara/kexploit` — not `$(SRCROOT)/lara/kexploit/pe`. Kexploit `.m`
files outside `pe/` therefore import pe headers as `#import "pe/apfs.h"`
(see `ota.m`, `mis.m`, `screentime.m`). `#import "pe/security_ext.h"` works with
the current search paths and matches that majority convention. If the
integration pass normalises the bridging header to bare `pe` imports by adding
`$(SRCROOT)/lara/kexploit/pe` to `HEADER_SEARCH_PATHS`, the equivalent line is
`#import "security_ext.h"`.

Inside `security_ext.m` the imports are bare (`darksword.h`, `xpf.h`), matching
the other files in `lara/kexploit/pe/` (`sbx.m`, `vfs.m`).

### 2. Navigation link

The new view is not referenced anywhere yet. Suggested wiring in
`lara/views/tweaks/TweaksView.swift` (new "Security" section, or add to the
"System" section):

```swift
Section(header: HeaderLabel(text: "Security", icon: "lock.shield")) {
    NavigationLink("Kernel Security Toggles", destination: SecurityTogglesView())
        .disabled(!mgr.dsready)
}
```

`TweaksView` already disables the whole list when `!mgr.dsready`, and the view
additionally gates every action itself.

### 3. Xcode project

Nothing to do. `lara/` is a `PBXFileSystemSynchronizedRootGroup`, so
`views/tweaks/security/SecurityTogglesView.swift` and the two `kexploit/pe`
files are picked up automatically. `libxpf.dylib` is already linked/embedded
(used by `offsets.m`/`vfs.m`) and `security_ext.m` only uses headers those files
already use.

## API

```objc
bool sec_proc_enforce_supported(void);       // resolve + read check
long sec_get_proc_enforce(void);             // 1 = enforced, 0 = not enforced, -1 = failure
bool sec_set_proc_enforce(long value);       // 0/1 only; write + read-back verify
NSDictionary *sec_amfi_probe(void);          // READ-ONLY
bool sec_amfi_write(NSString *varName, long value); // only "cs_enforcement_disable", 0/1
```

`sec_amfi_probe()` returns one entry per variable with these keys:

| Key | Type | Meaning |
| --- | --- | --- |
| `resolved` | `NSNumber(bool)` | a candidate address was found |
| `addr` | `NSString` | `"0x..."` runtime kernel address (`""` if unresolved) |
| `value` | `NSNumber` | 32-bit value read at that address (absent if unresolved) |
| `verified` | `NSNumber(bool)` | candidate is inside a kernel data section XPF exposes |
| `note` | `NSString` | `section-verified`, `heuristic (not section-verified)`, possibly with `value is not 0/1`, or `unresolved` |

When kernel r/w is not ready the probe returns `@{ @"error": @"kernel r/w not ready" }`.

## Safety model

- Defaults are untouched: nothing is written until the user types `RISK`
  (disable / AMFI write) or `ENFORCE` (re-enable).
- Every destructive action is read-before, written, and read-back verified.
  The Swift layer treats a failed read-back as failure and says so in the log.
- All writes refuse unless the current value is 0 or 1 (plausibility check).
- All actions are gated on `mgr.dsready`; the ObjC layer also re-checks
  `ds_is_ready()` on every call.
- The MAC variable is only written as 0 or 1; the AMFI write path only accepts
  the single hard-coded name `cs_enforcement_disable`.
- Everything is logged with a `(sec)` prefix via `printf` (captured by the app
  log) and `globallogger` on the Swift side.
- Resolution results are cached in `NSUserDefaults` under
  `lara.sec.<name>.off` / `.verified`. A cached MAC offset is re-validated at
  read time; a cached AMFI offset is re-validated by the write path's 0/1
  plausibility check. Clearing the app's defaults re-resolves everything.
- Reboot restores all values (nothing is persisted into the kernelcache file).

## What is proven vs best-effort

Ground truth below comes from the 26.0 kernelcache `kernelcache.release.iphone14c`
(iPhone14,6 / 23A341), kernel base `0xfffffff007004000`, plus the upstream
XPF/ChOma sources (`xpf_pfsec_init` definitions) that `libxpf.dylib` is built
from.

### Proven

- `mac_proc_enforce` is resolvable **deterministically**: the sysctl oid entry
  for the `proc_enforce` string sits in main `__DATA_CONST.__const` (name slot
  `0xfffffff007afbe68`), `oid_arg1` = `0xfffffff00aa7fe3c` (main
  `__DATA.__data`, value `1`), generic int handler and descr
  "Enforce MAC policy on processes". This matches XNU's
  `unsigned int mac_proc_enforce = 1; SYSCTL_UINT(..., proc_enforce, ...,
  &mac_proc_enforce, 0, "Enforce MAC policy on process operations")`.
  `sec_resolve_sysctl_var_locked()` implements this route; `verified` is `true`.
- The existing `getmacprocenforceoff()` in `offsets.m` **cannot** resolve this
  variable on 26.0: the `proc_enforce` string has no code xref in main, AMFI or
  prelink text (it is only referenced by the oid table), so its
  string → code-xref step returns 0. It is dead code, as suspected. We did not
  call it (it starts its own XPF session and would always fail); instead
  `sec_resolve_code_ref_var_locked()` replicates the same pattern as a fallback.
- All four AMFI strings exist in AMFI `__TEXT.__cstring`
  (`0xfffffff00751cbb8..0xfffffff00752885b`) and have ADRP+ADD references in
  AMFI `__TEXT_EXEC.__text` (`cs_enforcement_disable` at `0xfffffff00949fa04`,
  `amfi_enforce_launch_constraints` at `0xfffffff0094993ec`,
  `amfi_allow_3p_launch_constraints` at `0xfffffff009499408`,
  `amfi_enforce_cc_types` at `0xfffffff00949941c`).
- `amfi_get_out_of_my_way` does not exist in 26.0 and is not referenced.
- XPF's `kernelDataSection` / `kernelDataConstSection` are the **main kernel's**
  `__DATA.__data` and `__DATA_CONST.__const` sections only. AMFI data lives at
  `0xfffffff00ac47f68..0xfffffff00ac48791` (`__DATA`) and
  `0xfffffff007ce1fd0..0xfffffff007ce6060` (`__DATA_CONST.__const`), outside
  both. Therefore AMFI results can never be `section-verified` on this build and
  are always reported as heuristic. This is expected, not a bug.
- The MAC variable has no direct code load/store in main or AMFI text on this
  build, so its behavioural effect on iOS 26 is unproven (XNU gates the
  `__mac_syscall` check behind `SECURITY_MAC_CHECK_ENFORCE`, which appears to be
  compiled out here). The toggle is mechanically verified (read/write/read-back)
  but do not promise a visible security change.

### Best-effort

- All AMFI address resolution. The variables are boot-arg targets, not sysctls;
  the heuristic picks the nearest LDR/STR reference to the string xref and can
  land on a related field. On 23A341 the resolver is expected to produce the
  following **unslid kernelcache addresses** (the UI shows the runtime address,
  which is `kernel_base + (addr - 0xfffffff007004000)`):
  `cs_enforcement_disable -> 0xfffffff007ce3b24`,
  `amfi_enforce_launch_constraints -> 0xfffffff007ce372c`,
  `amfi_allow_3p_launch_constraints -> 0xfffffff007ce372c`,
  `amfi_enforce_cc_types -> 0xfffffff007ce3724` (all AMFI `__DATA_CONST`).
  These are build-specific; always read the UI/log output instead of trusting
  these numbers on another version.
- The **effect** of writing `cs_enforcement_disable`. On 23A341 the resolved
  address is written once during AMFI init (boot-arg storage) and no other
  direct reference was found, so the write may be ineffective even though the
  read-back succeeds. Code-signing enforcement may be handled by TXM/SPTM on
  26.0. The UI warning says this.
- Cache validity across kernelcache/OS updates: offsets are build-relative and
  are only weakly re-validated (0/1 value checks).

## Resolver details (for future maintainers)

`sec_resolve_code_ref_var_locked()`:

1. find the variable-name string (AMFI cstring → main cstring → prelink text),
2. find a code xref to it (`XREF_TYPE_MASK_REFERENCE`, AMFI text → main text →
   prelink text),
3. walk outward from the xref (`0, +1, -1, +2, -2, ...`, window ±16) and call
   `pfsec_arm64_resolve_adrp_ldr_str_add_reference_auto()` on each instruction,
4. take the first candidate that is not the string itself, is not inside a
   known text/string section and is above the kernel base; load/store references
   win over plain adds because a plain add near a boot-arg parse usually points
   at a string or a function argument,
5. mark `verified` when the candidate is inside `kernelDataSection` or
   `kernelDataConstSection`.

`sec_resolve_sysctl_var_locked()` (MAC):

1. find the sysctl name string in main `__cstring`,
2. scan `__DATA_CONST.__const` for an 8-byte slot whose decoded pointer
   (`pfsec_read_pointer`, chained-fixup decoder) equals the string address,
3. read `oid_arg1 = slot - 0x10` and `oid_handler = slot + 0x8`, require arg1 to
   be inside kernel data and warn if the handler is not in kernel text,
4. mark `verified` when arg1 is inside `kernelDataSection` /
   `kernelDataConstSection`.

Both helpers assume XPF is already started and hold the module's recursive lock;
`sec_xpf_start()` refuses when `Documents/kernelcache` is missing. We do not call
`xpf_construct_offset_dictionary()` because none of the offset sets are needed
for these scans (and the `translation` set is unsupported on SPTM devices).

## Known limitations

- No symbol table: everything is heuristic except the sysctl route.
- The MAC resolver's sysctl scan depends on the `struct sysctl_oid` layout
  (`oid_arg1` = name-0x10, `oid_handler` = name+0x8). A future XNU layout change
  silently disables resolution (the UI then shows "unresolved"; nothing crashes).
- AMFI variables are never section-verified on 26.0 by design of the exposed
  sections.
- Concurrent use of `xpf_*` from other features (e.g. a future caller of
  `getmacprocenforceoff()`) is not coordinated with this module's lock.
- `sec_amfi_write()` has no internal typed-confirmation token; the UI gate is
  mandatory. Do not call it from anywhere else.

## Testing checklist (device)

1. Integrate, build, run the exploit until `mgr.dsready`.
2. Open "Kernel Security Toggles": MAC row should resolve and show
   `enforced` (value 1). If it shows `unresolved`, check the app log for
   `(sec) sysctl:` lines and that `Documents/kernelcache` exists.
3. Tap "Run AMFI probe". Expect four rows; on 23A341 all four are heuristic and
   `amfi_enforce_launch_constraints` / `amfi_allow_3p_launch_constraints` share
   an address. That is the honest best-effort output.
4. MAC toggle: switch "Disable MAC enforcement", type `RISK`, Apply. The log
   must show `old 1 -> 0`, `read back 0`. Revert with `ENFORCE` (or reboot).
5. AMFI write (only if you accept the risk): type `RISK`, write 1, confirm the
   log shows `read back 1`, then restore the original value. If the write fails
   (read-only page / wrong address), the log shows `FAILED` and the value stays
   unchanged.
6. Reboot to clear all runtime changes.

## Rollback / removal

- Reboot restores every value; nothing survives a reboot.
- Remove the navigation link and the bridging header import to uninstall.
- Optional: clear the `lara.sec.*` keys from the app's `NSUserDefaults` to force
  re-resolution on the next run.
