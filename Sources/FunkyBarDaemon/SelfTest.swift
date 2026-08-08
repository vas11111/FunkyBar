import AppKit
import Foundation

/// Verifies the bar is genuinely on screen, without needing a screenshot.
///
/// Screen *capture* requires the Screen Recording TCC grant, which a headless
/// build cannot obtain. Asking the window server what it thinks of our own
/// windows needs no permission at all and answers a better question: not
/// "does it look right" but "is there a real, visible, correctly-placed,
/// correctly-levelled window where we asked for one".
@MainActor
enum SelfTest {

    struct WindowInfo {
        let id: Int
        let bounds: CGRect
        let layer: Int
        let alpha: Double
        let onScreen: Bool
    }

    static func serverWindows() -> [WindowInfo] {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return raw.compactMap { entry in
            guard entry[kCGWindowOwnerPID as String] as? pid_t == pid else { return nil }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }

            return WindowInfo(
                id: entry[kCGWindowNumber as String] as? Int ?? 0,
                bounds: bounds,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 0,
                onScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            )
        }
    }

    /// Returns a report and whether every check passed.
    static func run(runtime: BarRuntime) -> (report: String, passed: Bool) {
        var lines: [String] = []
        var failures: [String] = []

        func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("  \(passed ? "ok  " : "FAIL") \(name): \(detail)")
            if !passed { failures.append(name) }
        }

        lines.append("runtime")
        lines.append(runtime.status.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))

        // AppKit's view of our windows.
        let panels = NSApp.windows
        lines.append("\nAppKit windows: \(panels.count)")
        for panel in panels {
            lines.append("""
              frame=\(short(panel.frame)) level=\(panel.level.rawValue) \
            visible=\(panel.isVisible) opaque=\(panel.isOpaque) \
            behavior=\(panel.collectionBehavior.rawValue)
            """)
        }

        check("a window exists", !panels.isEmpty, "\(panels.count) panel(s)")
        check("every window is visible", panels.allSatisfy { $0.isVisible }, "isVisible")
        check(
            "every window is non-opaque",
            panels.allSatisfy { !$0.isOpaque },
            "the bar is transparent; items draw their own pills"
        )
        check(
            "every window joins all spaces",
            panels.allSatisfy { $0.collectionBehavior.contains(.canJoinAllSpaces) },
            "canJoinAllSpaces"
        )
        check(
            "every window is above normal",
            panels.allSatisfy { $0.level.rawValue > NSWindow.Level.normal.rawValue },
            "level > normal"
        )

        // The window server's view, which is the one that actually matters.
        let server = serverWindows()
        lines.append("\nwindow server: \(server.count) window(s) owned by this process")
        for window in server {
            lines.append("  id=\(window.id) bounds=\(short(window.bounds)) "
                         + "layer=\(window.layer) alpha=\(window.alpha) onScreen=\(window.onScreen)")
        }

        check(
            "the server agrees the window exists",
            !server.isEmpty,
            "\(server.count) window(s)"
        )
        check(
            "the server reports it on screen",
            server.contains { $0.onScreen },
            "kCGWindowIsOnscreen"
        )
        check(
            "the window has non-zero area",
            server.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 },
            "bounds"
        )
        check(
            "the window is not fully transparent",
            server.allSatisfy { $0.alpha > 0 },
            "alpha"
        )

        // One window per targeted display, not one per item. This is the whole
        // architectural bet: upstream would have 15 to 40 here.
        check(
            "one window per display, not one per item",
            server.count == runtime.displayCount,
            "\(server.count) window(s) for \(runtime.displayCount) display(s)"
        )

        let verdict = failures.isEmpty
            ? "\nall checks passed"
            : "\nFAILED: \(failures.joined(separator: ", "))"

        return (lines.joined(separator: "\n") + verdict, failures.isEmpty)
    }

    private static func short(_ rect: CGRect) -> String {
        String(
            format: "(%.0f,%.0f %.0fx%.0f)",
            rect.origin.x, rect.origin.y, rect.width, rect.height
        )
    }
}
