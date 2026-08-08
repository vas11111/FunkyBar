import AppKit
import Foundation
import FunkyBarCore
import IOKit.ps

// MARK: - Clock

/// Replaces `clock.sh`, which forks `sh` + `date` + a client round trip every
/// 10 seconds. This costs one `DateFormatter` call per minute.
@MainActor
public final class ClockProvider: Provider {
    public static let kind = "clock"

    public let itemID: String
    public let policy: UpdatePolicy

    private let timeFormatter = DateFormatter()
    private let dateFormatter = DateFormatter()

    public init(_ context: ProviderContext) {
        itemID = context.itemID
        // Default to a minute: the format shows minutes, so a faster tick
        // cannot change what is displayed.
        policy = .interval(seconds: context.interval ?? 60)

        timeFormatter.dateFormat = context.string("time") ?? "HH:mm"
        dateFormatter.dateFormat = context.string("date") ?? "EEE dd"
        timeFormatter.locale = .autoupdatingCurrent
        dateFormatter.locale = .autoupdatingCurrent
    }

    public func start(emit: @escaping @MainActor (ProviderUpdate) -> Void) {}

    public func refresh() -> ProviderUpdate? {
        let now = Date()
        return ProviderUpdate(itemID: itemID, values: [
            "time": timeFormatter.string(from: now),
            "date": dateFormatter.string(from: now),
        ])
    }
}

// MARK: - Front app

/// Replaces `front_app.sh`. Fully event-driven, so switching apps costs one
/// notification rather than a fork.
@MainActor
public final class FrontAppProvider: Provider {
    public static let kind = "frontApp"

    public let itemID: String
    public let policy: UpdatePolicy = .event

    private var observer: NSObjectProtocol?

    public init(_ context: ProviderContext) {
        itemID = context.itemID
    }

    public func start(emit: @escaping @MainActor (ProviderUpdate) -> Void) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let update = self.refresh() else { return }
                emit(update)
            }
        }
    }

    public func refresh() -> ProviderUpdate? {
        let app = NSWorkspace.shared.frontmostApplication
        return ProviderUpdate(itemID: itemID, values: [
            "name": app?.localizedName ?? "",
            "bundle_id": app?.bundleIdentifier ?? "",
            "pid": app.map { String($0.processIdentifier) } ?? "",
        ])
    }

    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }
}

// MARK: - Battery

/// Replaces `battery.sh`, which runs `pmset` twice per invocation on a 120s
/// poll. This registers a run-loop source that fires only when the power state
/// actually changes, so the steady-state cost is zero.
@MainActor
public final class BatteryProvider: Provider {
    public static let kind = "battery"

    public let itemID: String
    /// Event-driven, with a slow floor so a missed notification self-corrects.
    public let policy: UpdatePolicy

    private let ramp: [String]
    private let chargingIcon: String?
    private var runLoopSource: CFRunLoopSource?
    private var emit: (@MainActor (ProviderUpdate) -> Void)?

    public init(_ context: ProviderContext) {
        itemID = context.itemID
        policy = .interval(seconds: context.interval ?? 300)
        ramp = context.strings("ramp") ?? []
        chargingIcon = context.string("charging")
    }

    public func start(emit: @escaping @MainActor (ProviderUpdate) -> Void) {
        self.emit = emit

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ raw in
            guard let raw else { return }
            let provider = Unmanaged<BatteryProvider>.fromOpaque(raw).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard let update = provider.refresh() else { return }
                provider.emit?(update)
            }
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    public func refresh() -> ProviderUpdate? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 0
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            let state: String
            if charging { state = "charging" }
            else if plugged { state = "plugged" }
            else if percent <= 10 { state = "critical" }
            else if percent <= 20 { state = "low" }
            else { state = "discharging" }

            var values: [String: String] = [
                "percent": String(percent),
                "state": state,
                "charging": charging ? "true" : "false",
                "plugged": plugged ? "true" : "false",
            ]
            if let icon = icon(for: percent, charging: charging || plugged) {
                values["icon"] = icon
            }
            if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 {
                values["time_remaining"] = "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
            }

            return ProviderUpdate(itemID: itemID, values: values)
        }
        return nil
    }

    /// Picks a glyph from the configured ramp, lowest charge first.
    private func icon(for percent: Int, charging: Bool) -> String? {
        if charging, let chargingIcon { return chargingIcon }
        guard !ramp.isEmpty else { return nil }
        let index = min(ramp.count - 1, max(0, percent * ramp.count / 100))
        return ramp[index]
    }

    public func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
        emit = nil
    }
}
