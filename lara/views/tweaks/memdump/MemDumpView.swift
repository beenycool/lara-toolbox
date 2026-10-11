//
//  MemDumpView.swift
//  lara
//
//  Memory Lab: per-process memory map + streaming dump, and quick strings.
//
//  Kernel R/W only (no sandbox escape): everything is driven by memdump.h
//  (lara/kexploit/pe/memdump.m), which walks the target vm_map and streams
//  pages through the same TaskRop helpers App Decrypt uses. Nothing here types
//  an address: the region list, the size estimate and the dump all come from
//  the kernel.
//

import SwiftUI

// MARK: - models

struct memproc: Identifiable, Hashable {
    let id = UUID()
    let pid: pid_t
    let name: String
    let path: String
    let uid: uid_t
    let foreground: Bool

    var subtitle: String {
        if !path.isEmpty { return "\(path) · uid \(uid)" }
        return "uid \(uid)"
    }
}

struct memregion: Identifiable, Hashable {
    let id = UUID()
    let start: UInt64
    let end: UInt64
    let size: UInt64
    let prot: String
    let protBits: Int
    let cls: Int
    let clsLabel: String
    let offset: UInt64
    let fileBacked: Bool
    let submap: Bool
    let willDump: Bool
    let skipReason: String

    var willDumpText: String {
        willDump ? "dump" : "skip"
    }

    var willDumpColor: Color {
        willDump ? .green : .secondary
    }

    var classColor: Color {
        switch cls {
        case 0: return .blue        // anon_rw
        case 1: return .purple      // stack
        case 2: return .green       // main binary data
        case 3: return .orange      // main binary text
        case 4: return .secondary   // file backed
        default: return .red        // unreadable / submap
        }
    }
}

enum memdumpmode {
    case full
    case strings
}

// Preset ids, kept in sync with md_preset_t in lara/kexploit/pe/memdump.h.
// Plain Ints on the Swift side so the C enum never has to be bridged by name.
private let md_preset_heap: Int = 0
private let md_preset_all_readable: Int = 1
private let md_preset_full: Int = 2

// MARK: - view

struct MemDumpView: View {
    @ObservedObject private var mgr = laramgr.shared

    // MARK: process list
    @State private var procs: [memproc] = []
    @State private var loadingprocs = false
    @State private var query = ""
    @State private var selected: memproc? = nil

    // MARK: region preview
    @State private var regions: [memregion] = []
    @State private var loadingregions = false
    @State private var estimatesize: UInt64 = 0
    @State private var binaryPath = ""
    @State private var regionCount = 0
    @State private var dumpableCount = 0

    // MARK: options
    @State private var preset = md_preset_heap
    @State private var includeLarge = false
    @State private var stringsKeyword = ""

    // MARK: run state
    @State private var running = false
    @State private var mode: memdumpmode = .full
    @State private var progress: Double = 0
    @State private var statusline = ""
    @State private var outputpath = ""
    @State private var cancelflag: ObjCBool = false
    @State private var loglines: [String] = []
    @State private var showdonealert = false
    @State private var doneresult = ""

    private let maxloglines = 200

    private var filtered: [memproc] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return procs }
        let q = trimmed.lowercased()
        return procs.filter { $0.name.lowercased().contains(q) || "\($0.pid)".contains(q) }
    }

    private var presetname: String {
        switch preset {
        case md_preset_heap: return "Heap + data + stack"
        case md_preset_all_readable: return "All readable (skip file-backed text)"
        case md_preset_full: return "Full (all readable)"
        default: return "Unknown"
        }
    }

    private var canrun: Bool {
        mgr.dsready && selected != nil && !running && !loadingregions
    }

    var body: some View {
        List {
            if !mgr.dsready {
                Section {
                    PlainAlert(
                        title: "Memory Lab is closed",
                        icon: "lock.shield",
                        text: "Kernel R/W is not ready. Run Darksword first (this is a kernel-only feature, no sandbox escape needed).",
                        color: .red
                    )
                }
            }

            processsection
            if selected != nil {
                regionsection
                optionssection
                runsection
                resultsection
            }
        }
        .navigationTitle("Memory Lab")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Name or pid")
        .onAppear {
            loadprocs()
        }
        .onChange(of: mgr.dsready) { ready in
            if ready { loadprocs() } else { procs.removeAll() }
        }
        .onChange(of: preset) { _ in
            rebuildregions()
        }
        .onChange(of: includeLarge) { _ in
            rebuildregions()
        }
        .alert("Memory Lab", isPresented: $showdonealert) {
            Button("OK") { showdonealert = false }
        } message: {
            Text(doneresult)
        }
    }

    // MARK: - process list

    private var processsection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    loadprocs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loadingprocs || running || !mgr.dsready)

                if loadingprocs {
                    ProgressView()
                    Text("Reading process list...")
                        .foregroundColor(.secondary)
                } else {
                    Text("\(procs.count) processes")
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            if !running {
                ForEach(filtered) { proc in
                    Button {
                        selectproc(proc)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected?.pid == proc.pid ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selected?.pid == proc.pid ? .accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(proc.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(proc.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text("pid \(proc.pid)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        } header: {
            HeaderLabel(text: "Processes", icon: "apps.iphone")
        } footer: {
            Text("kernel_task (pid 0) is excluded. Tap a process to walk its vm_map.")
        }
    }

    // MARK: - region preview
    @State private var regionerror: String? = nil

    private var regionsection: some View {
        Section {
            if let error = regionerror {
                PlainAlert(title: "Region walk failed", icon: "exclamationmark.triangle",
                           text: error, color: .red)
            }

            if loadingregions {
                HStack {
                    ProgressView()
                    Text("Walking vm_map...")
                        .foregroundColor(.secondary)
                }
            } else if regions.isEmpty {
                Text("No regions yet.")
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    Text("\(regionCount) regions, \(dumpableCount) will be dumped")
                        .font(.subheadline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(estimatesize), countStyle: .file))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(dumpableCount > 0 ? .primary : .red)
                }

                ForEach(regions.prefix(60)) { region in
                    regionrow(region)
                }

                if regions.count > 60 {
                    Text("... \(regions.count - 60) more regions not shown")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if !binaryPath.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Main binary")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Text(binaryPath)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            HeaderLabel(text: "Region map", icon: "mappin.and.ellipse")
        } footer: {
            Text("Estimated size for the current preset. Regions come from the kernel; re-validated right before they are read.")
        }
    }

    private func regionrow(_ region: memregion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: "0x%llx", region.start))
                    .font(.system(.subheadline, design: .monospaced))
                Text("–")
                Text(String(format: "0x%llx", region.end))
                    .font(.system(.subheadline, design: .monospaced))

                Spacer()

                Text(region.willDumpText)
                    .font(.caption2.bold())
                    .foregroundColor(region.willDumpColor)
            }

            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(region.size), countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(region.prot)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                Text(region.clsLabel)
                    .font(.caption)
                    .foregroundColor(region.classColor)

                Spacer()

                if !region.skipReason.isEmpty {
                    Text(region.skipReason)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - options

    private var optionssection: some View {
        Section {
            Picker(selection: $preset) {
                Text("Heap + data + stack").tag(md_preset_heap)
                Text("All readable (skip file-backed text)").tag(md_preset_all_readable)
                Text("Full (all readable)").tag(md_preset_full)
            } label: {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text("Preset")
                }
            }
            .pickerStyle(.menu)

            Toggle("Include regions over 64 MB", isOn: $includeLarge)
                .font(.subheadline)

            Text("Overall cap: 512 MB. Per region: 64 MB unless the switch above is on. A per-region read failure becomes a hole, not a crash.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Quick strings keyword (optional)")
                    .font(.subheadline)
                TextField("e.g. https, password, bundle", text: $stringsKeyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }
        } header: {
            HeaderLabel(text: "Options", icon: "slider.horizontal.3")
        }
    }

    // MARK: - run

    private var runsection: some View {
        Section {
            Button {
                startdump()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("Dump process memory")
                }
            }
            .disabled(!canrun)

            Button {
                startstrings()
            } label: {
                HStack {
                    Image(systemName: "text.magnifyingglass")
                    Text("Quick strings")
                }
            }
            .disabled(!canrun)

            if running {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress)
                    HStack {
                        Text(statusline)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Cancel", role: .cancel) {
                            cancel()
                        }
                        .font(.footnote.bold())
                        .foregroundColor(.red)
                    }
                }
            }
        } header: {
            HeaderLabel(text: "Run", icon: "play.circle")
        } footer: {
            Text("Preset: \(presetname). Streaming: one 16 KB page at a time, straight to disk.")
        }
    }

    // MARK: - results

    private var resultsection: some View {
        Section {
            if !outputpath.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text(outputpath)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .onTapGesture {
                    UIPasteboard.general.string = outputpath
                    mgr.logmsg("(mem) copied path to clipboard")
                }
            }

            if !loglines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    ForEach(loglines.suffix(12), id: \.self) { line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            HeaderLabel(text: "Result", icon: "doc.text")
        } footer: {
            Text("Open Documents/lara_dumps in the file manager, then import the manifest with scripts/ghidra/lara_dump_to_ghidra.py.")
        }
    }

    // MARK: - actions

    private func loadprocs() {
        guard mgr.dsready, !running else { return }
        loadingprocs = true

        DispatchQueue.global(qos: .userInitiated).async {
            var result: [memproc] = []
            for case let entry as [String: Any] in mem_procs() ?? [] {
                guard let pid = entry["pid"] as? Int32 else { continue }
                let name = (entry["name"] as? String) ?? "pid \(pid)"
                result.append(memproc(
                    pid: pid,
                    name: name,
                    path: (entry["path"] as? String) ?? "",
                    uid: (entry["uid"] as? uid_t) ?? 0,
                    foreground: (entry["foreground"] as? Bool) ?? false
                ))
            }
            result.sort { $0.pid < $1.pid }

            DispatchQueue.main.async {
                procs = result
                loadingprocs = false
                mgr.logmsg("(mem) \(result.count) processes")
            }
        }
    }

    private func selectproc(_ proc: memproc) {
        guard !running else { return }
        selected = proc
        regions = []
        estimatesize = 0
        binaryPath = ""
        regionCount = 0
        dumpableCount = 0
        regionerror = nil
        rebuildregions()
    }

    private func rebuildregions() {
        guard let proc = selected, mgr.dsready else { return }
        loadingregions = true
        regionerror = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let dict = mem_regions(proc.pid, NSInteger(integerLiteral: preset), includeLarge) ?? [:]
            let fresh = parseRegions(dict)
            let error = dict["error"] as? String

            DispatchQueue.main.async {
                regions = fresh.regions
                estimatesize = fresh.total
                binaryPath = fresh.binaryPath
                regionCount = fresh.count
                dumpableCount = fresh.dumpable
                regionerror = error
                loadingregions = false
            }
        }
    }

    private func startdump() {
        guard let proc = selected else { return }
        guard mgr.dsready else {
            mgr.logmsg("(mem) kernel r/w not ready")
            return
        }

        begin(.full)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = mem_dump_process(
                proc.pid,
                NSInteger(integerLiteral: preset),
                includeLarge,
                0,
                mem_dumps_dir(),
                { value in
                    DispatchQueue.main.async {
                        progress = value
                    }
                },
                { message in
                    let text = message ?? ""
                    DispatchQueue.main.async {
                        statusline = text
                        appendlog(text)
                        mgr.logmsg("(mem) \(text)")
                    }
                },
                &cancelflag
            )
            finish(result ?? [:])
        }
    }

    private func startstrings() {
        guard let proc = selected else { return }
        guard mgr.dsready else {
            mgr.logmsg("(mem) kernel r/w not ready")
            return
        }

        begin(.strings)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = mem_quick_strings(
                proc.pid,
                includeLarge,
                0,
                mem_dumps_dir(),
                stringsKeyword,
                { value in
                    DispatchQueue.main.async {
                        progress = value
                    }
                },
                { message in
                    let text = message ?? ""
                    DispatchQueue.main.async {
                        statusline = text
                        appendlog(text)
                        mgr.logmsg("(mem) \(text)")
                    }
                },
                &cancelflag
            )
            finish(result ?? [:])
        }
    }

    private func begin(_ newmode: memdumpmode) {
        mode = newmode
        running = true
        progress = 0
        statusline = newmode == .full ? "Preparing dump..." : "Scanning strings..."
        cancelflag = false
        loglines.removeAll()
    }

    private func cancel() {
        guard running else { return }
        cancelflag = true
        statusline = "Cancelling..."
        appendlog(statusline)
    }

    private func finish(_ result: [AnyHashable: Any]) {
        DispatchQueue.main.async {
            running = false
            progress = 1.0

            let ok = (result["ok"] as? Bool) ?? false
            let partial = (result["partial"] as? Bool) ?? false
            let path = (result["path"] as? String) ?? ""
            outputpath = path

            let written = (result["written"] as? NSNumber)?.uint64Value ?? 0
            let scanned = (result["scanned"] as? NSNumber)?.uint64Value ?? 0
            let bytes = (result["bytes"] as? NSNumber)?.uint64Value ?? 0
            let error = (result["error"] as? String) ?? ""

            if mode == .strings {
                let keyword = stringsKeyword.isEmpty ? "all printable runs" : "matching \"\(stringsKeyword)\""
                doneresult = "Quick strings finished (\(keyword)): \(bytes) bytes written, \(scanned) bytes scanned. Folder: \(path)"
                mgr.logmsg("(mem) quick strings done -> \(path)")
            } else {
                let size = ByteCountFormatter.string(fromByteCount: Int64(written), countStyle: .file)
                doneresult = "Dump finished: \(size) written. Folder: \(path)"
                mgr.logmsg("(mem) dump done -> \(path) (\(size))")
            }

            if partial {
                appendlog("partial: \(error)")
                mgr.logmsg("(mem) partial dump kept at \(path) (\(error))")
            }

            // the region list is read from the manifest, refresh the preview so
            // the "will dump" column matches what actually happened
            rebuildregions()
            showdonealert = true
        }
    }

    private func appendlog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loglines.append(trimmed)
        if loglines.count > maxloglines {
            loglines.removeFirst(loglines.count - maxloglines)
        }
    }
}

// MARK: - parsing

private func parseRegions(_ dict: [AnyHashable: Any]) -> (regions: [memregion], total: UInt64, binaryPath: String, count: Int, dumpable: Int) {
    var regions: [memregion] = []
    var total: UInt64 = 0
    var dumpable = 0

    if let raw = dict["regions"] as? [[String: Any]] {
        for entry in raw {
            guard let region = memregion(dict: entry) else { continue }
            regions.append(region)
            if region.willDump {
                total += region.size
                dumpable += 1
            }
        }
    }

    let binaryPath = (dict["binaryPath"] as? String) ?? ""
    let count = (dict["regionCount"] as? NSNumber)?.intValue ?? regions.count
    return (regions, total, binaryPath, count, dumpable)
}

private extension memregion {
    init?(dict: [String: Any]) {
        guard
            let start = parseHex(dict["start"]),
            let end = parseHex(dict["end"]),
            let size = parseHex(dict["size"])
        else { return nil }

        self.start = start
        self.end = end
        self.size = size
        prot = (dict["prot"] as? String) ?? ""
        protBits = (dict["protBits"] as? NSNumber)?.intValue ?? 0
        cls = (dict["class"] as? NSNumber)?.intValue ?? 6
        clsLabel = (dict["classLabel"] as? String) ?? ""
        offset = parseHex(dict["offset"]) ?? 0
        fileBacked = (dict["fileBacked"] as? Bool) ?? false
        submap = (dict["submap"] as? Bool) ?? false
        willDump = (dict["willDump"] as? Bool) ?? false
        skipReason = (dict["skipReason"] as? String) ?? ""
    }
}

/// "0x1234" strings from ObjC, with a plain number fallback.
private func parseHex(_ value: Any?) -> UInt64? {
    switch value {
    case let string as String:
        return UInt64(string.replacingOccurrences(of: "0x", with: ""), radix: 16)
    case let number as NSNumber:
        return number.uint64Value
    default:
        return nil
    }
}
