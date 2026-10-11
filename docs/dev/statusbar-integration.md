# Status Bar Override Studio — integration notes

Live carrier/operator text override and status item refresh for SpringBoard, driven
through the existing RemoteCall primitive. Target verified against iOS 26.0
(23A341) SpringBoard strings.

- View: `lara/views/tweaks/StatusBarStudioView.swift`
- Integration (snippet below): add an entry in `RemoteView.swift` (preferred) or
  `TweaksView.swift`
- Reference pattern: `lara/kexploit/pe/rc.m` → `status_bar_time_format()` (lines 44–89)
- RemoteCall internals: `lara/kexploit/TaskRop/RemoteCall.{h,m}`

## 1. How it calls SpringBoard

`StatusBarStudioView` receives the same `mgr: laramgr` as every other RC screen and
uses `mgr.sbProc`, the `RemoteCall` instance bound to SpringBoard by
"Initialize RemoteCall".

The remote ObjC calls are made **from Swift** with the C bridge helpers declared in
`RemoteCall.h` (imported into Swift by `lara-Bridging-Header.h`, lines 17–18):

| Helper | Implementation | Used for |
| --- | --- | --- |
| `remote_getClass(proc, "UIApplication")` | `RemoteCall.m:1668` | class lookup |
| `remote_sel(proc, "statusBarStateAggregator")` | `RemoteCall.m:1659` | selector registration |
| `remote_msg(proc, obj, sel, a0…a3)` | `RemoteCall.m:1677` | `objc_msgSend` in SpringBoard (up to 4 args) |
| `remote_NSString(proc, "text")` | `RemoteCall.m:1689` | remote `NSString` argument |
| `remote_alloc_str(proc, "text")` | `RemoteCall.m:1633` | remote C string (UTF-8 fallback path) |
| `proc.remoteRead(_:to:size:)` | `RemoteCall.h:104` | reading the override back |

This is a deliberate Swift translation of `rc.m`'s proven call sequence, because
`rc.m`/`rc.h` and `laramgr.swift` are not touched by this feature:

```objc
// rc.m status_bar_time_format(), abbreviated
uiAppCls = remote_getClass(proc, "UIApplication");
app      = remote_msg(proc, uiAppCls, remote_sel(proc, "sharedApplication"), 0,0,0,0);
agg      = remote_msg(proc, app,     remote_sel(proc, "statusBarStateAggregator"), 0,0,0,0);
remote_msg(proc, agg, selPerform, selUpdateTime, 0 /*nil*/, 0 /*NO*/, 0);
```

### Why not `mgr.rccall(name:args:)`

`laramgr.rccall` (line 816) resolves a symbol with `dlsym(RTLD_DEFAULT, name)` in
the **Lara process** and feeds that pointer to `doStable`. That works for plain C
symbols that live in the dyld shared cache (same address in every process, e.g.
`getpid`, `exit`), but it cannot:

- register a remote selector (`sel_registerName` needs a remote C string),
- allocate a remote `NSString` for the `setUserNameOverride:` argument,
- carry out the `respondsToSelector:` gating this feature needs.

`remote_sel` / `remote_msg` / `remote_NSString` do exactly that, and they are the
helpers `rc.m` itself uses. Function pointers passed through RemoteCall
(`objc_msgSend`, `sel_registerName`, `strlen`, …) are shared-cache symbols, which
is why the same pointer is valid in SpringBoard.

### Call shape

1. Resolve `[[UIApplication sharedApplication] statusBarStateAggregator]` fresh on
   every action (never cache the pointer; SpringBoard recreates the aggregator on
   some display/lock transitions).
2. Gate every private selector with `respondsToSelector:` before sending it. An
   unrecognized selector would raise inside SpringBoard, which is the main crash
   risk of this feature.
3. Send the setter directly (one `NSString` argument).
4. Rebuild the status bar through
   `performSelectorOnMainThread:withObject:waitUntilDone:` with the `_update*`
   selector, a nil object and `waitUntilDone = NO` — same as `rc.m`.

All actions run on a `DispatchQueue.global(qos: .userInitiated)` queue (copied
from `RemoteView.run`), never on the main thread.

## 2. Selector inventory

| Selector | Sent to | Status | Notes |
| --- | --- | --- | --- |
| `sharedApplication` | `UIApplication` (class) | Proven | `rc.m` status bar path |
| `statusBarStateAggregator` | `UIApplication` instance | Proven | `rc.m` status bar path |
| `setUserNameOverride:` | `SBStatusBarStateAggregator` | Known (iOS 26 strings), guarded | one `NSString` arg; empty string = clear |
| `statusBarUserNameOverride` | `SBStatusBarStateAggregator` | Known (iOS 26 strings), guarded | getter, used by "Read current override" |
| `_updatePersonNameItem` | `SBStatusBarStateAggregator` | Known (iOS 26 strings), guarded | dispatched on SpringBoard main thread |
| `_updateDataNetworkItem` | `SBStatusBarStateAggregator` | Known (iOS 26 strings), guarded | dispatched on SpringBoard main thread |
| `_updateBatteryItems` | `SBStatusBarStateAggregator` | Known (iOS 26 strings), guarded | refresh only, marked experimental |
| `_updateOverrideDate` | `SBStatusBarStateAggregator` | Known (iOS 26 strings), guarded | zero-argument refresh, no date setter |
| `_updateTimeItems` | `SBStatusBarStateAggregator` | Proven | `rc.m` status bar path |
| `setOverrideDate:` (NSDate) | `SBStatusBarStateAggregator` | **Not verified** | TODO, see §6 |
| battery override setter | `SBStatusBarStateAggregator` | **Not identified** | not exposed |

Argument passing itself is proven (`setUserNameOverride:` takes one object;
`performSelectorOnMainThread:withObject:waitUntilDone:` takes three), so a verified
`setOverrideDate:` could be implemented later with `remote_msg`. The blocker for
the date override is the **unverified setter name/signature**, not argument
plumbing.

## 3. What the UI does

- **Status** — `mgr.rcready` / `mgr.sbProc` readiness (same check `RemoteView`
  uses), last `RemoteCall.lastError`, and the "Read current override" button.
  When not ready it shows the same wording `RemoteView` shows
  ("RemoteCall is not initialized. How are you here?") plus the concrete
  instruction to run the exploit and tap *Initialize RemoteCall* for SpringBoard.
- **Carrier / Operator Text** — text field (max 64 chars) + **Apply**
  (`setUserNameOverride:` then `_updatePersonNameItem` / `_updateDataNetworkItem`)
  and **Clear** (`setUserNameOverride:` with `@""`, same refresh). Both log which
  update selectors actually ran and which were missing on the running build.
- **Status Items** — **Repair status bar** re-dispatches every `_update*` selector
  the aggregator responds to; **Refresh battery items (experimental)** calls only
  `_updateBatteryItems`. No fake battery values are offered because no setter was
  verified.
- **Time Override** — **Refresh clock** calls `_updateOverrideDate` (zero args).
  Setting a date is intentionally absent; see §6.
- **Last Result** — monospaced log of the last action, mirrored to `mgr.logmsg`.

Failure strings contain `-> failed` so the existing alert path
(`isRemoteCallFailure` copied from `RemoteView`) fires when something breaks.

## 4. Risks

1. **RemoteCall is unstable.** It hijacks a live SpringBoard thread. A wedged or
   crashed SpringBoard is the worst case; recovery is a respring/reboot.
2. **Unrecognized selector = SpringBoard crash.** Mitigated by
   `respondsToSelector:` gating for every private selector. Do not add calls
   without that gate.
3. **Overrides are volatile.** `setUserNameOverride:` state lives in SpringBoard
   memory only. Respring, SpringBoard restart, and some display/lock transitions
   wipe it; re-apply or tap Clear.
4. **Remote string leak.** The ASCII path uses the proven `remote_NSString` (which
   frees its own C buffer). The non-ASCII fallback allocates a remote C buffer
   that is intentionally leaked: no remote `free()` helper is exposed to Swift.
   Bounded (a few bytes per Apply).
5. **Timeouts.** The C helpers use `RemoteArbCall`'s default timeout (5), which
   `RemoteCall.m` clamps to a ~10 s wait. A hung SpringBoard can block the calling
   background queue for that long; the UI shows `running` in the meantime.
6. **Shared RemoteCall thread state.** Do not run this screen concurrently with
   another RC action (RemoteView buttons, JIT, etc.). The app has no global RC
   lock; concurrent `remote_msg` calls can corrupt the hijacked thread state.
7. **Version drift.** Private selectors are not API. Missing selectors are
   reported by the UI instead of being called.

## 5. Integration snippet

Preferred: inside `RemoteView.swift`, right after the existing "Status Bar Time
Format" `Section` (ends around line 50), while the List body is in scope:

```swift
Section {
    NavigationLink("Status Bar Override Studio", destination: StatusBarStudioView(mgr: mgr))
} header: {
    Text("Status Bar")
} footer: {
    Text("Carrier text overrides and status item refreshes via RemoteCall into SpringBoard.")
}
```

`RemoteView` is already pushed inside `TweaksView`'s `NavigationStack`, so the
`NavigationLink` works as-is. `StatusBarStudioView` handles the not-ready case
itself, so no extra `.disabled` gate is needed here.

Alternative: in `TweaksView.swift`, SpringBoard section next to "RemoteCall
Customizer":

```swift
NavigationLink("Status Bar Studio", destination: StatusBarStudioView(mgr: mgr))
    .disabled(!mgr.rcready)
```

## 6. TODO / future work

- **Date override setter.** Verify in the iOS 26.0 SpringBoard binary whether
  `SBStatusBarStateAggregator` implements `-setOverrideDate:` (NSDate) and/or
  `-overrideDate`, and whether `_overrideDate` is an ivar settable via
  `setValue:forKey:`. Then either implement it in the view or (preferred) add a
  `status_bar_override_date(RemoteCall *, time_t)` helper to `rc.m`/`rc.h` so the
  call lives with the other proven primitives.
- **Battery override setter.** Enumerate `SBStatusBarStateAggregator` setters in
  Ghidra; expose fake battery level/charging only after a setter is verified.
- **Dual-SIM / data network.** `_updateDataNetworkItem` is dispatched, but the
  operator item may differ per SIM slot; validate on a dual-SIM device.
- **Read-back formatting.** `statusBarUserNameOverride` read-back is raw UTF-8;
  consider surfacing the fallback ("nil" vs empty string) more explicitly.
- **Migrate to `rc.m` helpers** if the constraint "only create the view + doc"
  is lifted, so all SpringBoard calls sit in one reviewed place.

## 7. Testing checklist

1. Exploit → *Initialize RemoteCall* (SpringBoard) → confirm Status shows Ready.
2. Open Tweaks → RemoteCall Customizer → Status Bar Override Studio.
3. *Read current override* → expect "(no override set)" on a fresh boot.
4. Apply `lara` → carrier text in the status bar changes within ~1 s; log lists
   `_updatePersonNameItem` and `_updateDataNetworkItem`.
5. Apply a non-ASCII value (e.g. `🚗 lara`) → exercises the UTF-8 fallback.
6. *Clear* → carrier returns to blank/default.
7. *Repair status bar* → log lists all five `_update*` selectors on iOS 26.
8. *Refresh battery items* → no visible change expected; must not crash.
9. Respring → override gone (expected); repeat from step 3 to confirm recovery.
10. While a call is running, verify the screen's buttons are disabled and no other
    RC screen is used simultaneously.
