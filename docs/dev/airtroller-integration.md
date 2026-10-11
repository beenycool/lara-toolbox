# AirTroller — reverse engineering + integration notes

Feature: replicate the classic *AirTroller* prank on iOS 26 — start an AirDrop
transfer at a target, then cancel it right as the target receives it, in a loop.

* Program: `Sharing` (Mach-O, AARCH64:LE:64:AppleSilicon), Ghidra project
  `/home/ubuntu/projects/apple_carplay/carplay.gpr`
* Second program used for the share-sheet send path: `SharingUI`
* Target device this was written for: iPhone SE 3 (iPhone14,6), iOS 26.0
  (23A5308g), sideloaded through SideStore (no kernel exploit involved —
  this is pure framework use, nothing is gated on `laramgr` state).

## Files added (nothing else was touched)

| file | purpose |
| --- | --- |
| `lara/lara/Sharing/AirTrollerBridge.h` | runtime "shape" protocols + bridge API |
| `lara/lara/Sharing/AirTrollerBridge.m` | all `SFAirDropBrowser` / `SFAirDropNode` access |
| `lara/lara/Sharing/AirTrollerManager.swift` | discovery poll, target list, Survey/Troll loop |
| `lara/lara/views/tweaks/airtroller/AirTrollerView.swift` | SwiftUI |
| `docs/dev/airtroller-integration.md` | this file |

The `lara/` source root is a `PBXFileSystemSynchronizedRootGroup` in
`lara.xcodeproj` (only `Info.plist` is an exception), so no project edit is
needed — new files under `lara/lara/` are picked up automatically.

## Bridging header line to add

`lara/lara-Bridging-Header.h` was **not** edited. Add this line with the other
`#import "..."` lines (before `#import <zlib.h>`):

```objc
#import "Sharing/AirTrollerBridge.h"
```

The path is relative: the bridging header lives in `lara/lara/`, the bridge in
`lara/lara/Sharing/`, and `HEADER_SEARCH_PATHS` only contains `$(SRCROOT)/lara`
(non-recursive), so a bare `#import "AirTrollerBridge.h"` would **not** resolve.
If you would rather not use the `Sharing/` prefix, the alternative is to add
`$(SRCROOT)/lara/Sharing` to `HEADER_SEARCH_PATHS` (an edit to the project file)
and keep the bare import — the relative import avoids touching the project.

## Wiring the view (needs one edit to an existing file)

Nothing was added to the existing navigation. Add this to the Tweaks list
(`lara/views/tweaks/TweaksView.swift`, next to the other `NavigationLink` rows):

```swift
NavigationLink("AirTroller", destination: AirTrollerView(mgr: mgr))
```

## Reverse engineering: the send path

### `-[SFAirDropNode startSendForBundleID:sessionID:items:description:previewImage:fromShareSheet:]` — `Sharing @ 0x1a9068bc8`

```text
locks (3 recursive)
if (self->_operation != NULL) return            // one send per node
_airdrop_log("...")                              // "no operation" path
_SFOperationCreate(0, cf_Sender)  -> self->_operation
_SFOperationSetClient(...)
_SFOperationSetDispatchQueue(self->_operation, global queue)
_SFOperationSetProperty(op, cf_Node,       self->_node)          // ivar + 0x90
_SFOperationSetProperty(op, cf_BundleID,   bundleID)             // only if != NULL
_SFOperationSetProperty(op, cf_FileIcon,   previewImage)         // only if != NULL
_SFOperationSetProperty(op, cf_FromShareSheet, @(fromShareSheet))
_SFOperationSetProperty(op, cf_Items,      items)                // always
_SFOperationSetProperty(op, cf_SessionID,  sessionID)            // only if != NULL
_SFOperationSetProperty(op, cf_ItemsDescription, description)    // only if != NULL
_SFOperationResume(self->_operation)
unlocks
```

Consequences used by the implementation:

* only one send may be in flight per node (a second call is a silent no-op), so
  the loop **must** cancel (or wait) between cycles;
* every argument except `items:` is optional — `nil` simply skips the property;
* `fromShareSheet:` is just a boolean stored in `cf_FromShareSheet`.

### Where the share sheet builds the arguments — `SharingUI @ 0x1b931fa68`

`-[SFAirDropActivityViewController startTransferForPeople:]` is the only caller
(the single xref to `_objc_msgSend$startSendForBundleID:...@0x1b93b4d20` comes
from `0x1b931fe94` inside it). The call site is:

```asm
1b931fe58  mov  x0, x23                       ; preview photo
1b931fe5c  fmov d0, d8                         ; scale 4096.0
1b931fe60  bl   0x1b932e69c                    ; _SFScaleAndRotateImage
1b931fe70  mov  x0, x21
1b931fe74  bl   0x1b93ab840                    ; CGImage
1b931fe78  mov  x6, x0                         ; <-- previewImage
1b931fe7c  ldr  x0, [sp, #0x48]                ; <-- receiver (SFAirDropNode)
1b931fe80  mov  x2, x20                        ; <-- bundleID   (self + ivar 0xdf8)
1b931fe84  mov  x3, x22                        ; <-- sessionID  (self + ivar 0xe18)
1b931fe88  mov  x4, x27                        ; <-- items
1b931fe8c  mov  x5, x25                        ; <-- description
1b931fe90  mov  w7, #0x0                       ; <-- fromShareSheet = NO
1b931fe94  bl   0x1b93b4d20                    ; startSendForBundleID:...
```

### Argument format findings

| argument | value | confidence |
| --- | --- | --- |
| `bundleID:` | `NSString*` read from the activity controller's own property (ivar `+0xdf8`), i.e. the sending app's bundle id — the browser gets the same string through `-[SFAirDropBrowser setSendingAppBundleID:]` | **verified** (register trace) |
| `sessionID:` | `NSString*` read from the activity controller's own property (ivar `+0xe18`); `SharingUI` declares `T@"NSString",&,N,V_sessionID` (the property sits next to `SFAirDropMagicHeadViewController`'s `_delegate`), so a UUID *string* is the natural value | **verified** (register trace + property type encoding), format of the string itself (uuid vs uuid5) is best-effort |
| `items:` | `NSMutableArray` built by `arrayWithCapacity:` from `-[SFAirDropPayload URL]` (`_objc_msgSend_URL` + `addObject:`), so **an `NSArray` of `NSURL`** (file URLs). String payloads are first turned into file URLs by `-createURLPayloadForData:...`, so they end up in the same array | **verified** |
| `description:` | `NSString*` from `-[SFAirDropPayload payloadDescription]` (`T@"NSString",C,N,V_payloadDescription`), the first matching payload's description | **verified** |
| `previewImage:` | `CGImageRef` — `_SFScaleAndRotateImage(4096.0, previewPhoto)` followed by a CGImage conversion, so a `CGImage`, **not** a `UIImage`; it is stored in `cf_FileIcon` and **may be nil** (the setter is skipped) | **verified** |
| `fromShareSheet:` | `BOOL`; **the share sheet itself passes `NO`** (`mov w7, #0x0`), i.e. `NO` does not necessarily mean "no UI" — it means "this send was not initiated by the sheet's own accept button". `NO` is still the right choice for a silent send (that is the path `SFAirDropMagicHeadViewController` uses) | **verified** at this call site, the *effect of the flag is best-effort* |

What the implementation passes:

* `bundleID:` = `Bundle.main.bundleIdentifier`
* `sessionID:` = one `NSUUID().uuidString` per manager instance (stable across
  cycles, same for browser and send)
* `items:` = `[@(tmp/AirTroller-payload.txt)]`, a tiny text file written by
  `+[AirTrollerBridge preparePayloadFile]`
* `description:` = `"AirTroller test payload"`
* `previewImage:` = `nil` by default, a generated `CGImage` when "attach preview
  image" is on
* `fromShareSheet:` = `NO` by default

## Reverse engineering: discovery

`SFAirDropBrowser` (`Sharing`):

| selector | address | note |
| --- | --- | --- |
| `-init` | `0x1a9063f24` | allocates `_operation`, `_nodeIDToNode`, `_people` |
| `-start` | `0x1a9063fe8` | `_SFBrowserCreate(0, cf_AirDrop)`, `_SFBrowserSetClient`, `_SFBrowserSetDispatchQueue(global queue)`, `_SFBrowserSetOptions`, `_SFBrowserOpenNode(browser, NULL, self->_root, NULL)` |
| `-stop` | `0x1a9064208` | |
| `-pause` / `-resume` | `0x1a9064158` / `0x1a90641b4` | |
| `-people` | `0x1a9065450` | ivar `+0x28`, sorted `NSArray` of `SFAirDropNode` |
| `-nodeIDToNode` | `0x1a9065530` | ivar `+0x60` |
| `-setSendingAppBundleID:` | `0x1a90654d0` | |
| `-setSessionID:` | `0x1a9065448` | |
| `-setUrlsBeingShared:` | `0x1a90654e0` | also passed here for realism |
| `-updateDiscoveredPeople` | `0x1a9064244` | `_SFBrowserCopyChildren`, `+[SFAirDropNode nodeWithSFNode:]` / `-updateWithSFNode:`, `setNodeIdentifier:` = `[NSUUID UUID]`, diff + `sortUsingComparator:` |

`SFAirDropNode` accessors that are used: `-displayName`, `-displayNameForLocale:`,
`-realName`, `-nodeIdentifier` (`NSUUID`), `-model`, `-formattedHandles`,
`-isDisabled`, `-isMe`, `-isKnown`, `-isRapport`, `-cancelSend`,
`-startSendForBundleID:...`. No process id is ever read or shown.

### Two discovery mechanisms, both implemented

1. **Poll** (default, always on): a `DispatchWorkItem` re-armed every 1.5s on the
   `lara.airtroller` queue calls `-[SFAirDropBrowser people]` and maps the
   snapshot to `AirTrollerTarget` on the main queue.
2. **Delegate accelerator** (bonus): `AirTrollerBrowserDelegate` implements the
   only `SFAirDropBrowserDelegate`-adjacent selectors that actually exist in the
   binary (`browser:didInsertPersonAtIndex:`,
   `browser:didDeletePersonAtIndex:`, `browserDidChangePeople:`,
   `browserDidUpdateMePeople:knownPeople:unknownPeople:`) and is installed with
   `-setDelegate:`. It only *re-triggers a snapshot*, so if the real protocol
   names differ on device, nothing is lost.

> Note: the browser mutates `people` on its own queue, so a snapshot read is
> theoretically racy even though the `@synchronized` in the bridge keeps our own
> threads apart. Symptoms would be a crash or a briefly stale list. The delegate
> path (fires on the browser's own queue) is the safer default if it turns out
> to work on device.

## The SFOperation event machine

`-[SFAirDropNode handleOperationCallback:event:withResults:]` — `Sharing @ 0x1a9068e18`

`_SFOperationSetClient`'s C callback (`_operationCallBack @ 0x1a9068ddc` /
`0x1a906c29c`) is `(operation, event, results, client)` and dispatches
`[client handleOperationCallback:operation event:event withResults:results]`, i.e.
the node itself is the client. There is **no delegate hook a third-party app can
install** (`SFAirDropNode` has no delegate ivar — the ivar list is only data:
`_actualHandles`, `_classroom`, `_contact`, `_displayIcon`, `_displayName`,
`_endpointUUID`, `_formattedHandles`, `_me`, `_model`, `_monogram`, `_node`,
`_nodeIdentifier`, `_rangingMeasurement`, `_realName`, `_secondaryName`,
`_selectionReason`, `_suggestion`, `_transportBundleID`, …). And
`method_setImplementation` / swizzling is not an option: the classes live in the
dyld shared cache, whose `__DATA` is not writable for a sideloaded app.

So the event machine is *driven* (synthetic replay) rather than observed:

```text
event < 5 :   2 -> _SFOperationResume(op)      ("AskUser", answer the prompt)
              3 -> no-op                       ("WaitForAnswer")
              4 -> cancelSend                  ("Cancelled")
event < 0x10: (1 << event) & 0xc9e0 != 0 -> normal completion, no cancel
                  5 Started, 6 Preprocess, 7 Progress, 8 Postprocess,
                  11 Connecting, 14 Blocked, 15 Converting
              9 -> cancelSend                  ("Finished")
              10 -> log "Sender kSFOperationEventErrorOccured %@" then cancelSend
              (0, 1, 12, 13) -> log only
anything else: log only
log format for unhandled: "Sender UNHANDLED EVENT %@ [%d] %@"
```

### Event names

`_SFOperationEventToString` @ `0x1a9068f18` indexes
`PTR_cf_NewOperation_1e7a850a8` with `(event - 1)` for `1 … 15`. The 15 CFString
constants were read out of the binary:

| event | name | node action |
| ---: | --- | --- |
| 0 | — (out of range → `-`) | log only |
| 1 | NewOperation | log only |
| 2 | AskUser | `_SFOperationResume` |
| 3 | WaitForAnswer | no-op |
| 4 | Cancelled | auto `cancelSend` |
| 5 | Started | completion, no cancel |
| 6 | Preprocess | completion, no cancel |
| 7 | Progress | completion, no cancel |
| 8 | Postprocess | completion, no cancel |
| 9 | Finished | auto `cancelSend` |
| 10 | ErrorOccured | log + auto `cancelSend` |
| 11 | Connecting | completion, no cancel |
| 12 | Information | log only |
| 13 | Conflict | log only |
| 14 | Blocked | completion, no cancel |
| 15 | Converting | completion, no cancel |
| ≥16 | — | log only |

`+[AirTrollerBridge nameForOperationEvent:]` tries
`dlsym(RTLD_DEFAULT, "_SFOperationEventToString")` first (it is a private symbol,
so it will usually fail) and falls back to the decoded table. The framework's
misspelling of `ErrorOccured` is kept so log lines match the framework.

### Survey mode

* performs exactly one send, with the full 7 arguments logged;
* then replays every event number **except 2** through
  `handleOperationCallback:event:withResults:` and logs
  `event <n> "<name>" -> <action>`.

Event `2` is deliberately skipped: it makes the node call
`_SFOperationResume(<whatever we passed>)`, and with no live `SFOperationRef`
that is a guaranteed crash.

### Troll mode

```text
loop until stopped (or max cycles):
    startSendToNode:...items:[payload] fromShareSheet:NO
    wait trigger (default 350 ms, 0…2000)
    cancelSendToNode:
    wait gap (default 500 ms, 0…5000)
    cycle counter++
```

`stop()` sets a lock-protected flag; the trigger/gap sleeps are sliced into 20 ms
chunks that re-check the flag, so the loop exits within ~20 ms and never blocks
the main queue.

The intended "natural" trigger is event `2`/`AskUser` (the target's
Accept/Decline prompt appearing) or event `5`/`Started`. Since the events cannot
be received today, the UI keeps a trigger *event* picker for that purpose but
fall back to a fixed delay and say so in the log.

## Still needs device verification

1. `SFAirDropBrowser` / `SFAirDropNode` resolve at all in a SideStore build
   (`Sharing` is linked by UIKit, so this is expected — `+isSupported` and the
   `dlopen` fallback cover it).
2. The `items:` format really is `NSArray<NSURL *>` with file URLs in this app's
   sandbox (verified statically; confirm the payload is accepted).
3. `fromShareSheet: NO` really suppresses the picker.
4. `previewImage:` as a `CGImage` vs `nil` — does either one change whether the
   target's device actually rings?
5. Are `bundleID` / `sessionID` allowed to be arbitrary? (Any entitlement that
   requires the sender to match a known app would show up here as an event 10
   `ErrorOccured` early in the cycle.)
6. Whether `SFAirDropBrowserDelegate`'s real selector set matches the four
   selectors implemented (if not, the poll loop keeps it working).
7. The exact delay that lands the cancel on the target's prompt (350 ms is a
   guess; the Survey cycle's `+<ms>` timestamps give a first data point).

## Device-test checklist

1. Build with the bridging-header import from above + the `NavigationLink`.
2. Open AirTroller; "AirDrop classes" must read `available`.
3. Start browsing with the target's AirDrop set to *Everyone*; the target must
   appear in the list (name from `displayNameForLocale:`).
4. Survey mode → Start: one line per cycle
   (`startSendForBundleID:…fromShareSheet:NO`) followed by the event dump, and
   the target should show a transient request that then disappears.
5. Troll mode, gap 500 ms, max cycles 5 → Start: exactly 5 cycles, counter
   reaches 5, the log shows the `+<ms>` timestamps.
6. Stop mid-run: the loop must end within ~20 ms (slice-limited sleep).
7. Re-run with `fromShareSheet: YES` and confirm the difference (picker or not).
8. Kill the target's AirDrop visibility mid-run: discovery should drop the node
   and the run should end with "no live node handle" rather than crash.
9. Leave the app in the background for a minute, come back: no crash, browsing
   resumes.
10. Every action above must have produced a `(airtroller) …` line in the global
    log (`LogsView` / `lara.log`).
11. Low risk check: the target's *Contacts-only* AirDrop should not receive
    anything if the sender is not in its contacts.

## Threading model

| work | queue |
| --- | --- |
| `-[SFAirDropBrowser init/start/stop]` | `lara.airtroller` (background) |
| `-[SFAirDropBrowser people]` snapshot | `lara.airtroller` (or the browser's own callback queue for the delegate) |
| `startSendForBundleID:…`, `cancelSend`, event replay | `lara.airtroller` |
| `@Published` updates, target diffing, logging | main |
| `globallogger` / `laramgr.logmsg` | main (they hop internally) |

Stop requests are a lock-protected flag read in 20 ms sleep slices, so the loop
never blocks the main queue and always exits promptly.
