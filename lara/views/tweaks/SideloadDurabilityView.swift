//
//  SideloadDurabilityView.swift
//  lara
//
//  Sideload durability pack: manages MobileIdentityService provisioning state
//  (profile expiry, launch warnings, rejected/banned lists) through the
//  ObjC helpers in kexploit/mis.h.
//

import SwiftUI

struct SideloadDurabilityView: View {
    @ObservedObject private var mgr = laramgr.shared

    private static let fiveYears: Int64 = 5 * 365 * 24 * 60 * 60
    private static let bannedPlists = [
        "Rejections.plist",
        "AuthListBannedUpps.plist",
        "AuthListBannedCdHashes.plist",
    ]
    private static let allPlists = bannedPlists + ["UserOverriddenCdHashes.plist"]

    private struct StatusRow: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let warn: Bool
    }

    @State private var statusRows: [StatusRow] = []
    @State private var diagnostics = "not loaded"
    @State private var logLines: [String] = []
    @State private var working = false
    @State private var alertMessage: String?
    @State private var showExtendConfirm = false
    @State private var showRestoreConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(statusRows) { row in
                        HStack {
                            Text(row.label)
                            Spacer()
                            Text(row.value)
                                .monospaced()
                                .foregroundColor(row.warn ? .red : .green)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    HeaderLabel(text: "Status", icon: "clock.arrow.circlepath")
                } footer: {
                    Text("Sideloaded apps lose their free profile after 7 days. This panel manages the provisioning state MobileIdentityService keeps in mis.db and its ban lists.")
                }

                Section {
                    ScrollView {
                        Text(diagnostics)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 140)
                } header: {
                    HeaderLabel(text: "Diagnostics", icon: "stethoscope")
                } footer: {
                    Text("Live schema from sqlite_master / PRAGMA table_info plus the plists found on disk.")
                }

                Section {
                    if working {
                        HStack {
                            ProgressView()
                            Text("Working…")
                                .foregroundColor(.secondary)
                        }
                    }

                    Button("Backup mis.db") {
                        backupDatabase()
                    }
                    .disabled(!mgr.sbxready || working)

                    Button("Extend Profiles +5 Years") {
                        showExtendConfirm = true
                    }
                    .disabled(!mgr.sbxready || working)
                    .alert("Extend profile expiries?", isPresented: $showExtendConfirm) {
                        Button("Cancel", role: .cancel) { }
                        Button("Extend", role: .destructive) { extendProfiles() }
                    } message: {
                        Text("Sets profiles.expires for every row in mis.db to now + 5 years. A daemon restart or reboot may be needed for the change to apply.")
                    }

                    Button("Clear Launch Warnings") {
                        clearLaunchWarnings()
                    }
                    .disabled(!mgr.sbxready || working)

                    Button("Unban Lists (empty plists)") {
                        unbanLists()
                    }
                    .disabled(!mgr.sbxready || working)

                    Button("Restore Newest Backups") {
                        showRestoreConfirm = true
                    }
                    .disabled(!mgr.sbxready || working)
                    .alert("Restore newest backups?", isPresented: $showRestoreConfirm) {
                        Button("Cancel", role: .cancel) { }
                        Button("Restore", role: .destructive) { restoreBackups() }
                    } message: {
                        Text("Overwrites the ban list plists and mis.db with their newest lara_backups copies. Reboot afterwards.")
                    }
                } header: {
                    HeaderLabel(text: "Actions", icon: "wrench.and.screwdriver")
                } footer: {
                    Text("Signing/provisioning state only: profile expiry, launch warnings and rejected/banned lists. Requires a working sandbox escape.")
                }

                Section {
                    if logLines.isEmpty {
                        Text("No activity yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView {
                            Text(logLines.joined(separator: "\n"))
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 120, maxHeight: 240)
                    }

                    Button("Clear Log") {
                        logLines.removeAll()
                    }
                    .disabled(logLines.isEmpty)
                } header: {
                    HeaderLabel(text: "Log", icon: "list.bullet.rectangle")
                } footer: {
                    Text("Entries are mirrored into lara.log.")
                }
            }
            .navigationTitle("Sideload Durability")
            .alert("Result", isPresented: .constant(alertMessage != nil)) {
                Button("OK") { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .onAppear {
                refresh()
            }
            .onChange(of: mgr.sbxready) { _, ready in
                if ready {
                    refresh()
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        guard mgr.sbxready else {
            statusRows = [StatusRow(label: "Sandbox escape", value: "not ready", warn: true)]
            diagnostics = "sandbox escape not ready - nothing to read"
            return
        }
        guard !working else { return }

        let sandboxReady = mgr.sbxready
        let vfsReady = mgr.vfsready
        working = true

        DispatchQueue.global(qos: .userInitiated).async {
            let status = statusDictionary()
            let present = (mis_list_plists() as [String]?) ?? []

            var rows = buildStatusRows(status, sandboxReady: sandboxReady, vfsReady: vfsReady)
            let plists = buildPlistSummary(present)
            let backups = buildBackupSummary()
            rows.append(StatusRow(label: "Banned plists", value: plists, warn: present.isEmpty))
            rows.append(StatusRow(label: "Backups", value: backups, warn: false))

            let diag = buildDiagnostics(status, presentPlists: present)

            DispatchQueue.main.async {
                working = false
                statusRows = rows
                diagnostics = diag
            }
        }
    }

    private func backupDatabase() {
        runAction(title: "Backup mis.db",
                  success: "mis.db copied into lara_backups.",
                  failure: "Backup failed - check the log.") {
            mis_backup_db()
        }
    }

    private func extendProfiles() {
        runAction(title: "Extend profiles",
                  success: "profiles.expires set to now + 5 years.",
                  failure: "Extend failed - check the log.") {
            mis_extend_profiles(Self.fiveYears)
        }
    }

    private func clearLaunchWarnings() {
        runAction(title: "Clear launch warnings",
                  success: "launch_warning.user_override set to 1.",
                  failure: "Clear failed - check the log.") {
            mis_clear_launch_warnings()
        }
    }

    private func unbanLists() {
        runAction(title: "Unban lists",
                  success: "Ban list plists emptied (backups kept).",
                  failure: "Unban failed - check the log.") {
            mis_unban_plists()
        }
    }

    private func restoreBackups() {
        guard mgr.sbxready else {
            appendLog("Restore: skipped, sandbox escape not ready")
            alertMessage = "Sandbox escape is not ready."
            return
        }
        guard !working else { return }

        working = true
        appendLog("Restore: starting…")
        DispatchQueue.global(qos: .userInitiated).async {
            let plistsOK = mis_restore_plists()
            let dbOK = mis_restore_db()
            DispatchQueue.main.async {
                working = false
                appendLog("Restore: plists \(plistsOK ? "ok" : "failed"), mis.db \(dbOK ? "ok" : "failed")")
                alertMessage = (plistsOK || dbOK)
                    ? "Restored newest backups. Reboot recommended."
                    : "Restore failed - check the log."
                refresh()
            }
        }
    }

    private func runAction(title: String,
                           success: String,
                           failure: String,
                           _ action: @escaping () -> Bool) {
        guard mgr.sbxready else {
            appendLog("\(title): skipped, sandbox escape not ready")
            alertMessage = "Sandbox escape is not ready."
            return
        }
        guard !working else { return }

        working = true
        appendLog("\(title): starting…")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = action()
            DispatchQueue.main.async {
                working = false
                appendLog("\(title): \(ok ? "ok" : "failed")")
                alertMessage = ok ? success : failure
                refresh()
            }
        }
    }

    // MARK: - Status rendering

    private func buildStatusRows(_ status: [String: Any],
                                 sandboxReady: Bool,
                                 vfsReady: Bool) -> [StatusRow] {
        var rows: [StatusRow] = []
        rows.append(StatusRow(label: "Sandbox escape",
                              value: sandboxReady ? "ready" : "not ready",
                              warn: !sandboxReady))
        rows.append(StatusRow(label: "VFS fallback",
                              value: vfsReady ? "ready" : "unavailable",
                              warn: false))

        let dbExists = bool(status["dbExists"])
        let dbSize = int64(status["dbSize"]) ?? 0
        rows.append(StatusRow(label: "mis.db",
                              value: dbExists ? "found (\(dbSize / 1024) KB)" : "missing",
                              warn: !dbExists))

        let opened = bool(status["opened"])
        if dbExists && !opened {
            rows.append(StatusRow(label: "sqlite",
                                  value: string(status["error"]) ?? "open failed",
                                  warn: true))
        }

        if opened {
            if let count = int64(status["profilesCount"]) {
                rows.append(StatusRow(label: "Profiles",
                                      value: "\(count) rows",
                                      warn: false))
            }
            if let minExpires = int64(status["minExpires"]), let maxExpires = int64(status["maxExpires"]) {
                rows.append(StatusRow(label: "Expiry range",
                                      value: "\(expiryString(minExpires)) → \(expiryString(maxExpires))",
                                      warn: false))
            } else if status["profilesExpiresColumn"] != nil || status["profilesTableMissing"] != nil {
                rows.append(StatusRow(label: "Expiry range",
                                      value: "unknown (schema)",
                                      warn: true))
            }

            if let warningRows = int64(status["launchWarningRows"]) {
                let overridden = int64(status["launchWarningOverridden"]) ?? 0
                rows.append(StatusRow(label: "Launch warnings",
                                      value: "\(warningRows) rows / \(overridden) overridden",
                                      warn: false))
            } else if status["launchWarningTableMissing"] != nil {
                rows.append(StatusRow(label: "Launch warnings",
                                      value: "table missing",
                                      warn: true))
            } else if status["launchWarningOverrideColumn"] != nil {
                rows.append(StatusRow(label: "Launch warnings",
                                      value: "user_override missing",
                                      warn: true))
            }
        }

        return rows
    }

    private func buildDiagnostics(_ status: [String: Any], presentPlists: [String]) -> String {
        var lines: [String] = []

        let dbPath = string(status["dbPath"]) ?? "/private/var/db/MobileIdentityData/mis.db"
        lines.append("db: \(dbPath)")
        lines.append("exists: \(bool(status["dbExists"]) ? "yes" : "no")  wal: \(bool(status["walExists"]) ? "yes" : "no")  shm: \(bool(status["shmExists"]) ? "yes" : "no")")
        lines.append("opened: \(bool(status["opened"]) ? "yes" : "no")")

        if let error = string(status["error"]) {
            lines.append("error: \(error)")
        }

        let tables = stringArray(status["tables"])
        lines.append("tables (\(tables.count)): \(tables.isEmpty ? "(none)" : tables.joined(separator: ", "))")

        if let columns = status["columns"] as? NSDictionary {
            for table in tables {
                let tableColumns = stringArray(columns[table])
                lines.append("  \(table): [\(tableColumns.joined(separator: ", "))]")
            }
        }

        var checks: [String] = []
        if status["profilesTableMissing"] != nil { checks.append("profiles table MISSING") }
        if status["profilesExpiresColumn"] != nil { checks.append("profiles.expires MISSING") }
        if status["launchWarningTableMissing"] != nil { checks.append("launch_warning table MISSING") }
        if status["launchWarningOverrideColumn"] != nil { checks.append("launch_warning.user_override MISSING") }
        lines.append("schema checks: \(checks.isEmpty ? "all expected columns present" : checks.joined(separator: "; "))")

        lines.append("plists:")
        for name in Self.allPlists {
            lines.append("  \(name): \(presentPlists.contains(name) ? "present" : "missing")")
        }

        lines.append("backups: \(string(status["backupDir"]) ?? "?")")
        return lines.joined(separator: "\n")
    }

    private func buildPlistSummary(_ present: [String]) -> String {
        guard !present.isEmpty else { return "none visible" }
        let missing = Self.allPlists.filter { !present.contains($0) }
        var value = "\(present.count)/\(Self.allPlists.count) present"
        if !missing.isEmpty {
            value += " (missing: \(missing.joined(separator: ", ")))"
        }
        return value
    }

    private func buildBackupSummary() -> String {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "no Documents directory"
        }
        let directory = documents.appendingPathComponent("lara_backups")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: keys,
                                                                       options: []) else {
            return "none yet"
        }
        guard !files.isEmpty else { return "none yet" }

        let newest = files.max { lhs, rhs in
            let left = ((try? lhs.resourceValues(forKeys: Set(keys)))?.contentModificationDate) ?? .distantPast
            let right = ((try? rhs.resourceValues(forKeys: Set(keys)))?.contentModificationDate) ?? .distantPast
            return left < right
        }
        return "\(files.count) file(s), newest \(newest?.lastPathComponent ?? "?")"
    }

    // MARK: - Helpers

    private func statusDictionary() -> [String: Any] {
        guard let raw = mis_status() as [AnyHashable: Any]? else { return [:] }
        var result: [String: Any] = [:]
        for (key, value) in raw {
            if let key = key as? String {
                result[key] = value
            }
        }
        return result
    }

    private func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private func int64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }

    private func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as? String }
        }
        return []
    }

    private func expiryString(_ epoch: Int64) -> String {
        guard epoch > 0 else { return "n/a" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.append("\(formatter.string(from: Date()))  \(message)")
        if logLines.count > 250 {
            logLines.removeFirst(logLines.count - 250)
        }
        globallogger.log("(mis) \(message)")
    }
}
