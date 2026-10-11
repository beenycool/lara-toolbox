import CarPlay
import UIKit

/// Builds Lara's CarPlay template hierarchy.
///
/// Design notes (from RE of iOS 26 CarPlay.framework):
/// - Scene -> Screen mapping is owned by `CPTemplateApplicationScene`
///   (`_screenForScene:`, `_updateSceneTraitsAndPushTraitsToScreen:`).
/// - Car window creation is gated by `_shouldCreateCarWindow`, which reduces
///   to the `com.apple.developer.carplay-maps` entitlement check
///   (`_CPCurrentProcessHasMapsEntitlement`). Without an Apple-approved
///   CarPlay entitlement the head unit will refuse our scene on a real car;
///   the simulator still renders it for development.
/// - There is no public API for pixel-level screen mirroring. This manager
///   therefore exposes status + safe actions as list templates.
enum LaraCarPlayManager {

    /// - Parameter setRoot: escape hatch to replace the root template
    ///   (used after async refresh).
    static func makeRootTemplate(
        setRoot: @escaping (CPTemplate, Bool) -> Void
    ) -> CPListTemplate {
        let statusSection = CPListSection(
            items: [exploitStatusItem(), offsetsStatusItem(), versionItem()],
            header: "Status",
            sectionIndexTitle: nil
        )

        let actionsSection = CPListSection(
            items: [
                runExploitItem(setRoot: setRoot),
                respringItem(),
                logsItem(),
                aboutMirroringItem(),
            ],
            header: "Actions",
            sectionIndexTitle: nil
        )

        let template = CPListTemplate(
            title: "Lara",
            sections: [statusSection, actionsSection]
        )
        template.showsTabBadge = false
        return template
    }

    // MARK: - Status items (read-only, no handler)

    private static func exploitStatusItem() -> CPListItem {
        let ready = laramgr.shared.dsready
        let item = CPListItem(
            text: ready ? "Exploit: ready" : "Exploit: not run",
            detailText: ready
                ? "Kernel R/W is up. Use the phone for the full toolbox."
                : "Run the exploit from the phone first.",
            image: nil
        )
        return item
    }

    private static func offsetsStatusItem() -> CPListItem {
        let ok = laramgr.shared.hasOffsets
        return CPListItem(
            text: ok ? "Offsets: present" : "Offsets: missing",
            detailText: ok
                ? "Kernelcache offsets loaded."
                : "Fetch offsets in Lara settings on the phone.",
            image: nil
        )
    }

    private static func versionItem() -> CPListItem {
        let v = UIDevice.current.systemVersion
        return CPListItem(
            text: "iOS \(v)",
            detailText: "Lara supports 17.0-18.7.1 and 26.0.x (no M5/A19).",
            image: nil
        )
    }

    // MARK: - Actions

    private static func runExploitItem(
        setRoot: @escaping (CPTemplate, Bool) -> Void
    ) -> CPListItem {
        let item = CPListItem(
            text: "Run Exploit",
            detailText: "Parked only. Same as the phone's Run button.",
            image: nil
        )
        item.handler = { _, completion in
            // Confirm: never run kernel exploits while driving.
            let confirm = CPAlertTemplate(
                titleVariants: ["Run exploit?"],
                actions: [
                    CPAlertAction(title: "Cancel", style: .cancel) { _ in
                        completion()
                    },
                    CPAlertAction(title: "Run (parked)", style: .default) { _ in
                        laramgr.shared.run()
                        completion()
                    },
                ]
            )
            // Push over the current stack via the interface controller is the
            // caller's job; here we ask the delegate to present by posting a
            // notification the scene delegate observes. Simplest robust path:
            // post, let the phone UI confirm, then dismiss.
            NotificationCenter.default.post(
                name: .laraCarPlayRequestsAlert,
                object: confirm
            )
            completion()
        }
        return item
    }

    private static func respringItem() -> CPListItem {
        let item = CPListItem(
            text: "Respring info",
            detailText: "Apply SpringBoard tweaks from the phone.",
            image: nil
        )
        item.handler = { _, completion in
            // Read-only from the car: respringing headless while driving is
            // unsafe, so we only explain instead of acting.
            completion()
        }
        return item
    }

    private static func logsItem() -> CPListItem {
        // Show the last few log lines as a detail list. Full log streaming
        // to the head unit would spam the driver; keep it short.
        let lines = Array(globallogger.logs.suffix(8))
        let items = lines.map { line in
            CPListItem(
                text: String(line.prefix(64)),
                detailText: nil,
                image: nil
            )
        }
        let item = CPListItem(
            text: "Recent logs (\(items.count))",
            detailText: items.first?.text ?? "No logs yet.",
            image: nil
        )
        item.handler = { _, completion in
            completion()
        }
        return item
    }

    private static func aboutMirroringItem() -> CPListItem {
        let item = CPListItem(
            text: "About screen mirroring",
            detailText: "CarPlay forbids it; templates only.",
            image: nil
        )
        item.handler = { _, completion in
            completion()
        }
        return item
    }
}

extension Notification.Name {
    /// Posted when the CarPlay UI wants the phone UI to present an alert.
    /// The main app observes this; CarPlay templates cannot run kernel code
    /// paths that assume a phone key window.
    static let laraCarPlayRequestsAlert = Notification.Name(
        "laraCarPlayRequestsAlert"
    )
}
