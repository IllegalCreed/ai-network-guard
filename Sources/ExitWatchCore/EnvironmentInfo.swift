import Foundation

/// A small, local-only snapshot of the execution environment used by the
/// native macOS dashboard.
public struct DeviceEnvironmentSnapshot: Sendable, Hashable {
    public let timeZoneIdentifier: String
    public let timeZoneOffsetSeconds: Int
    public let preferredLanguageIdentifier: String
    public let operatingSystemLabel: String

    public init(
        timeZoneIdentifier: String,
        timeZoneOffsetSeconds: Int,
        preferredLanguageIdentifier: String,
        operatingSystemLabel: String
    ) {
        self.timeZoneIdentifier = timeZoneIdentifier
        self.timeZoneOffsetSeconds = timeZoneOffsetSeconds
        self.preferredLanguageIdentifier = preferredLanguageIdentifier
        self.operatingSystemLabel = operatingSystemLabel
    }

    public static func current(
        timeZone: TimeZone = .current,
        preferredLanguages: [String] = Locale.preferredLanguages,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Self {
        let language = preferredLanguages.first
            ?? Locale.current.identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Self(
            timeZoneIdentifier: timeZone.identifier,
            timeZoneOffsetSeconds: timeZone.secondsFromGMT(),
            preferredLanguageIdentifier: language.isEmpty ? "未知" : language,
            operatingSystemLabel: "macOS \(operatingSystemVersion.majorVersion).\(operatingSystemVersion.minorVersion).\(operatingSystemVersion.patchVersion)"
        )
    }

    public var timeZoneOffsetLabel: String {
        Self.utcOffsetLabel(seconds: timeZoneOffsetSeconds)
    }

    public var timeZoneLabel: String {
        "\(timeZoneIdentifier) (\(timeZoneOffsetLabel))"
    }

    public static func utcOffsetLabel(seconds: Int) -> String {
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3_600
        let minutes = (absolute % 3_600) / 60
        if minutes == 0 {
            return "UTC\(sign)\(hours)"
        }
        return String(format: "UTC%@%02d:%02d", sign, hours, minutes)
    }
}
