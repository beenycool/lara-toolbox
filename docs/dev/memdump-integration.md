# Memory Lab (per-process memory dump)

`lara/views/tweaks/memdump/MemDumpView.swift` + `lara/kexploit/pe/memdump.{h,m}`

Dump one process's memory from the phone, and load the result into Ghidra at
the addresses the process actually used.

Per-process only. There is no physical / full RAM dump: Darksword is a kernel
read/write primitive, not a physmap primitive, so pages of *another* task are
reached the same way App Decrypt reaches them — a `vm_map` entry of the target
task, then a page mapped through TaskRop. Kernel memory is out of scope.

## Gates

Everything is gated on `mgr.dsready`.

No sandbox escape is needed: the whole path is kernel read/write. lara writes
into its own Documents folder, and every page is pulled out of the target's
`vm_object` by the kernel, so there is nothing to escape.

## What the engine does

```
pid
 └─ procbypid()            utils.m, existing
     └─ taskbyproc()       utils.m
         └─ task_get_vm_map()      utils.m
             └─ vmmapiterateentries()  TaskRop/vm.m, existing
                 └─ vmmapremotepage()  TaskRop/vm.m, one 16 KB page at a time
```

The walk is the same shape as `decrypt.m` (`find_macho_in_vm_map` /
`read_file_from_vm`), and that file is the reference for how the page reads
work.

### Region classification

Each `vm_map` entry is classified by reading the entry with
`ds_kreadbuf(entry, &ve, sizeof(struct vmmapentry))`, using the bitfield layout
in `TaskRop/vm.h` (`vme_alias` / `vme_offset` at `entry+0x40`, protection at
`entry+0x48` bit 7, `is_sub_map` at `vme_object_value` bit 1). The main binary
is found by mapping a page and checking for a Mach-O magic, exactly like App
Decrypt does, then its `LC_SEGMENT_64` commands are parsed to separate `__TEXT`
from `__DATA`.

| class | meaning | default preset |
|---|---|---|
| `anon_rw` | anonymous rw (malloc / heap / mmap scratch) | dump |
| `stack` | thread stack (heuristic, below) | dump |
| `main_binary_data` | `__DATA` / `__LINKEDIT` of the app binary | dump |
| `main_binary_text` | `__TEXT` of the app binary, recoverable from disk | skip |
| `file_backed_ro` | other file backed mapping (dylibs, shared cache) | skip |
| `other` | submap / unclassified | never |
| `unreadable` | prot none, not readable, sub-page | never |

Stack detection is a heuristic, in this order: the anonymous mapping that
contains the first thread's saved user SP (read through `machine.upcb`, the way
`crashproc()` does it), then the highest anonymous mapping of at least 512 KB.
It only affects the label — bounds still come from the map entry.

Presets:

| preset | id | contents |
|---|---|---|
| Heap + data + stack | 0 (default) | `anon_rw`, `stack`, `main_binary_data` |
| All readable (skip file-backed text) | 1 | everything readable except `main_binary_text` |
| Full (all readable) | 2 | every readable region |

### Caps and "no OOM"

* One 16 KB page resident at a time, streamed straight into the region file.
  A 512 MB dump does not allocate 512 MB.
* Free disk space is checked before anything is read
  (`NSFileSystemFreeSize`, need estimate + 32 MB margin).
* Regions over 64 MB are skipped unless "include regions over 64 MB" is on.
* Overall cap 512 MB; the remaining regions are recorded as skipped, not
  silently dropped, and the log says where it stopped.
* Progress callback, and a cancel flag polled between regions and pages.
* Every region's bounds come from a real `vm_map` entry and are re-validated
  (`vmmapfindentry` + `vmentrygetrange`) immediately before the read. A region
  whose bounds changed is skipped, never read at the old range. No address is
  typed by the user anywhere in the UI.

## Output layout

```
Documents/lara_dumps/
  <name>.<pid>.<UTC ts>/              (renamed from .tmp on completion)
    regions/
      <class>_0x<start>.bin
    manifest.json
    summary.txt
  strings-<name>.<pid>.<UTC ts>/      (quick strings, sibling folder)
    strings.txt
    manifest.json
    summary.txt
```

A cancelled or failed run keeps its files and renames to the final name with
`"partial": true` in the manifest.

`summary.txt` is the human readable one-pager: process, binary path, binary
base, per-region table with size / prot / class / file / skip reason.

### manifest.json

`format` is `lara-memdump-1`. Addresses are hex strings.

```json
{
  "format": "lara-memdump-1",
  "version": 1,
  "partial": false,
  "cancelled": false,
  "pid": 1337,
  "process": "TestApp",
  "binary_path": "/private/var/containers/Bundle/Application/.../TestApp",
  "binary_base": "0x1c000000",
  "started": 1760000000,
  "result": { "total_size": 0, "written_bytes": 0, "region_count": 0 },
  "regions": [
    {
      "start": "0x1c000000",
      "end": "0x1c004000",
      "size": 16384,
      "prot": "rw-",
      "protBits": 3,
      "class": "anon_rw",
      "classId": 0,
      "offset": "0x0",
      "fileBacked": false,
      "submap": false,
      "dumped": true,
      "complete": true,
      "bytes": 16384,
      "holes": 0,
      "skip_reason": "",
      "file": "regions/anon_rw_0x1c000000.bin"
    }
  ]
}
```

`skip_reason` values: `kernel_or_invalid_range`, `sub_page_or_empty`,
`prot_none`, `not_readable`, `submap`, `file_backed_text_recoverable_from_disk`,
`not_selected_by_preset`, `region_over_64mb`, `overall_size_cap_reached`,
`insufficient_free_space`, `page_map_failed`, `cancelled`,
`vm_map_changed_before_read`, `main_macho_not_located`.

## Quick strings

Same walker, same caps, but the output is `strings.txt`: one `0x<va> <run>`
line per printable run of at least 6 characters, streamed page by page. No
memory file is written. An optional keyword (case insensitive substring) filters
the runs.

## Ghidra import

`scripts/ghidra/lara_dump_to_ghidra.py`. It reads `manifest.json`, creates one
memory block per dumped region at its **original VA**, names the block
`<class>_0x<start>` (e.g. `anon_rw_0x1c000000`, `stack_0x1c010000`), sets R/W/X
from the region's protection, and sources the `.bin` into it.

In the GUI: open an empty program (`File > New > Empty Program`, language
`AARCH64:LE:64:v8A` if you want disassembly) and run the script from the Script
Manager; it asks for the dump folder. Pointing it at the parent `lara_dumps`
folder imports the newest dump found.

Headless, after copying the dump folder off the device:

```sh
$GHIDRA/support/analyzeHeadless /tmp/lara_proj lara_import \
    -import /tmp/empty.bin \
    -processor AARCH64:LE:64:v8A \
    -postScript lara_dump_to_ghidra.py /path/to/lara_dumps/TestApp.1337.20261011T120000Z
```

`-process` instead of `-import` re-runs on a program already in the project.
The path may also be `dumpDir=/path/to/dump`.

Notes that matter when you use it:

* The iPhone language id is `AARCH64:LE:64:v8A` (note `AARCH64`, not `ARM`:
  `ARM:LE:64:v8A` fails with "Unsupported language").
* Blocks are **not** relocated. `setImageBase(addr, true)` moves every block by
  the delta between the old and new base, which would destroy the original VAs
  of an already imported program, so on a program that already has blocks the
  base is left alone and the dumped blocks simply sit at their original
  addresses. On a truly empty program the base is established at the lowest
  dumped address.
* Pair the dump with the on-disk Mach-O by hand: `binary_path` and
  `binary_base` in the manifest give you the base to load the app binary at.

## Test results

The Ghidra script was run in this environment against a synthesised dump
(one `manifest.json`, three region `.bin` files, one `dumped: false` region)
with `analyzeHeadless` + `-postScript` on an imported 4 KB raw binary, then a
second script dumped the resulting memory map.

Observed:

```
[lara-dump] + anon_rw_0x1c000000         0x1c000000 - 0x1c004000  16384 bytes  prot=rw-
[lara-dump] + main_binary_data_0x1c004000 0x1c004000 - 0x1c00c000  32768 bytes  prot=r-x
[lara-dump] + stack_0x1c00c000           0x1c00c000 - 0x1c010000  16384 bytes  prot=rw-
[lara-dump] summary: 3 block(s) created, 0 failed, 1 not dumped, 65536 bytes imported
```

Independently verified with a second script against the saved program:

| block | range | R/W/X | initialized | bytes at start |
|---|---|---|---|---|
| `anon_rw_0x1c000000` | 0x1c000000-0x1c003fff | r, w | yes | `03 0a 11 18 …` (matches the `.bin` file) |
| `main_binary_data_0x1c004000` | 0x1c004000-0x1c00bfff | r, x | yes | `03 0a 11 18 …` |
| `stack_0x1c00c000` | 0x1c00c000-0x1c00ffff | r, w | yes | `03 0a 11 18 …` |

The `dumped: false` region produced no block. Pointing the script at the parent
`lara_dumps` folder resolved to the newest dump. A dump with two missing region
files produced two `WARNING:` lines, a `1 block(s) created, 2 failed` summary,
and no crash.

The GUI path (`askDirectory`) was not clicked through, only driven through the
headless argument path, which uses the same `askDirectory` call.

## Integration steps for the person wiring this in

* Add `#import "memdump.h"` to `lara/lara-Bridging-Header.h`.
* Add `lara/kexploit/pe/memdump.m` to the Xcode target and
  `views/tweaks/memdump/MemDumpView.swift` to the app sources.
* Show it from wherever you like, e.g. next to the other tools:
  `MemDumpView()` inside a `NavigationStack`.

Nothing in `lara/lara/kexploit/pe/memdump.m` reads a typed address, and it does
not write to the target process at all, so the only thing that can go wrong is
a styled "no regions" or "region changed" message.

## Known limits

* Per-process only. No physmap in this exploit, so no full physical memory dump
  and no kernel dump.
* The stack heuristic can pick the wrong region; the label is wrong, the data
  is not.
* Regions over 64 MB are skipped by default (JIT heaps, big mmaps); turn the
  switch on and expect a big file.
* Some mappings (IOMD pages inside a sub-map, device memory) may come back as
  holes; `holes` in the manifest counts them and `complete: false` marks the
  region.
* `main_binary_text` is recoverable from disk, which is why it is skipped; for
  an encrypted binary use App Decrypt first and the Ghidra pairing above.
* The dump is taken at a moment in time; a live process changes as you copy it.
* No debug symbols: class names and method names are not recovered, only raw
  memory plus whatever strings you find with quick strings.
