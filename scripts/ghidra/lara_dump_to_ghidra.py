# lara_dump_to_ghidra.py
# Ghidra script: import a lara "Memory Lab" dump into the current program.
#
# Reads manifest.json from a lara dump folder (produced by
# lara/kexploit/pe/memdump.m) and creates one memory block per dumped region,
# at its ORIGINAL virtual address, named "<class>_0x<start>", with R/W/X flags
# taken from the region's protection, and sources the region bytes into it.
# The image base is set to the lowest dumped address.
#
# Usage
#   GUI:  open (or create) an empty/raw program in Ghidra, then run this script
#         from the Script Manager (Window > Script Manager). It asks for the
#         dump folder with askDirectory.
#
#   headless:
#     <GHIDRA>/support/analyzeHeadless <tmpProjDir> lara_import \
#         -import dummy.bin \
#         -processor ARM:LE:64:v8A \
#         -postScript lara_dump_to_ghidra.py /path/to/<name>.<pid>.<ts>
#
#     analyzeHeadless -process works on an existing program too. The argument
#     may be a bare path or "dumpDir=/path/to/dump".
#
# Jython 2.7 compatible (Ghidra's own Python). Only the standard library is
# used, plus Ghidra's script globals (currentProgram, askDirectory, ...).

import os
import json

from java.io import ByteArrayInputStream


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def log(msg):
    print("[lara-dump] %s" % msg)


def parse_int(value, default=0):
    """Accept JSON ints, "0x..." strings and decimal strings."""
    if value is None or isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    text = str(value).strip()
    if not text:
        return default
    try:
        return int(text, 16) if text.startswith("0x") or text.startswith("0X") else int(text, 0)
    except ValueError:
        return default


def prot_to_flags(prot_string, prot_bits):
    """lara writes "rw-" style strings plus the raw vm_prot bits (R=1 W=2 X=4)."""
    bits = 0
    if isinstance(prot_bits, int) and prot_bits > 0:
        bits = prot_bits
    else:
        text = (prot_string or "").lower()
        if "r" in text: bits |= 1
        if "w" in text: bits |= 2
        if "x" in text: bits |= 4
    if bits == 0:
        bits = 3       # keep it readable so Ghidra shows bytes
    return (bits & 1) != 0, (bits & 2) != 0, (bits & 4) != 0


def block_name(region):
    """Block name = class label at the region start, e.g. heap_0x1c000000."""
    return "%s_0x%x" % (region.get("class", "region"), parse_int(region.get("start"), 0))


def dump_dir_from_arg(raw):
    """Script argument, "dumpDir=/path" or a plain path, or a parent folder."""
    if not raw:
        return None
    if "=" in raw:
        raw = raw.split("=", 1)[1]
    if os.path.isfile(raw) and raw.endswith(".json"):
        raw = os.path.dirname(raw)
    return find_dump_dir(raw)


def find_dump_dir(path):
    """path is a dump folder, or a parent folder containing dump folders."""
    if os.path.isfile(os.path.join(path, "manifest.json")):
        return path
    candidates = []
    for root, dirs, files in os.walk(path):
        if "manifest.json" in files and "regions" in dirs:
            try:
                with open(os.path.join(root, "manifest.json")) as handle:
                    data = json.load(handle)
                if str(data.get("format", "")).startswith("lara-memdump"):
                    candidates.append(root)
            except Exception:
                pass
    if not candidates:
        return None
    candidates.sort(key=lambda p: os.stat(os.path.join(p, "manifest.json")).st_mtime)
    return candidates[-1]


def get_dump_dir():
    """Script args in headless, askDirectory in the GUI (askDirectory also
    consumes script args itself, which is what we want in both cases)."""
    selected = askDirectory("lara dump folder", "Import")
    if selected is None:
        return None
    return find_dump_dir(str(selected))


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def run():
    log("lara memory dump importer")

    program = currentProgram
    if program is None:
        log("ERROR: no current program")
        return

    dump_dir = get_dump_dir()
    if not dump_dir:
        log("ERROR: no dump folder with a manifest.json was selected")
        return

    manifest_path = os.path.join(dump_dir, "manifest.json")
    try:
        with open(manifest_path) as handle:
            manifest = json.load(handle)
    except Exception as exc:
        log("ERROR: cannot read %s (%s)" % (manifest_path, exc))
        return

    regions = manifest.get("regions", []) or []
    if not regions:
        log("ERROR: manifest lists no regions")
        return

    log("dump folder : %s" % dump_dir)
    log("process     : %s (pid %s)" % (manifest.get("process", "?"), manifest.get("pid", "?")))
    log("binary path : %s" % manifest.get("binary_path", "(unknown)"))
    log("binary base : %s" % manifest.get("binary_base", "0x0"))
    log("partial     : %s" % manifest.get("partial", False))
    log("regions     : %d in manifest" % len(regions))

    memory = program.getMemory()

    # dumps are 64-bit addresses; prefer the "ram" space of the current program
    # and fall back to its default space.
    address_space = program.getAddressFactory().getAddressSpace("ram")
    if address_space is None:
        address_space = program.getAddressFactory().getDefaultAddressSpace()

    lowest = None
    created = 0
    failed = 0
    skipped = 0
    total_bytes = 0

    for region in regions:
        name = block_name(region)

        if not region.get("dumped", False):
            skipped += 1
            continue

        rel_file = region.get("file", "") or ""
        if not rel_file:
            skipped += 1
            continue

        region_file = os.path.join(dump_dir, rel_file)
        if not os.path.isfile(region_file):
            log("WARNING: region file is missing: %s" % region_file)
            failed += 1
            continue

        start = parse_int(region.get("start"), 0)
        end = parse_int(region.get("end"), 0)
        size = end - start if end > start else parse_int(region.get("size"), 0)
        if size <= 0:
            log("WARNING: %s has no usable size, skipped" % name)
            failed += 1
            continue

        with open(region_file, "rb") as handle:
            data = handle.read()
        if len(data) != size:
            log("WARNING: %s holds %d bytes, the manifest says %d, using the file size"
                % (name, len(data), size))
            size = len(data)

        read, write, execute = prot_to_flags(region.get("prot", ""),
                                             region.get("protBits", 0))

        if memory.getBlock(name) is not None:
            log("note: block %s already exists, removing it first" % name)
            try:
                memory.removeBlock(memory.getBlock(name))
            except Exception as exc:
                log("WARNING: could not remove %s (%s)" % (name, exc))
                failed += 1
                continue

        try:
            addr = address_space.getAddress(start)
            if addr is None:
                raise Exception("address 0x%x is not addressable" % start)

            # createInitializedBlock needs the script's TaskMonitor; the
            # "monitor" script global is it (falls back to no-op if absent).
            monitor = None
            try:
                monitor = globals()["monitor"]
            except KeyError:
                pass
            if monitor is None:
                from ghidra.util.task import TaskMonitor
                monitor = TaskMonitor.DUMMY

            # createInitializedBlock(name, start, data, length, monitor, overlay)
            # overlay must be False: with True Ghidra builds an overlay block
            # that sits on top of the loader's block and reads back as zeros.
            block = memory.createInitializedBlock(name, addr,
                                                  ByteArrayInputStream(data),
                                                  size, monitor, False)
            block.setRead(read)
            block.setWrite(write)
            block.setExecute(execute)
            block.setVolatile(True)
            created += 1
            total_bytes += size
            if lowest is None or start < lowest:
                lowest = start
            log("+ %-34s 0x%08x - 0x%08x  %-10d bytes  prot=%s%s%s"
                % (name, start, start + size, size,
                   "r" if read else "-", "w" if write else "-", "x" if execute else "-"))
        except Exception as exc:
            log("WARNING: could not create %s at 0x%x (%s)" % (name, start, exc))
            failed += 1

    # image base: setImageBase() *moves* every existing block by the delta
    # between the old and the new base, which would destroy the original VAs of a
    # program the user already imported. It is only called on a program with no
    # blocks at all, i.e. an empty program, where there is nothing to relocate.
    binary_base = parse_int(manifest.get("binary_base"), 0)
    pre_existing_blocks = len(list(memory.getBlocks()))
    if lowest is not None and pre_existing_blocks == 0:
        try:
            program.setImageBase(address_space.getAddress(lowest), True)
            log("image base: 0x%x (empty program, base established)" % lowest)
        except Exception as exc:
            log("note: could not set the image base (%s), blocks stay at 0x%x"
                % (exc, lowest))
    elif lowest is not None:
        log("image base: left as-is, this program already had %d block(s)"
            % pre_existing_blocks)
        log("            dumped blocks sit at their original VAs, lowest 0x%x" % lowest)
    else:
        log("note: no block was created, image base untouched")
    log("manifest binary base: 0x%x (pair the dump with the Mach-O at that base)"
        % binary_base)

    log("summary: %d block(s) created, %d failed, %d not dumped, %d bytes imported"
        % (created, failed, skipped, total_bytes))
    log("done")


run()
