import Foundation

/// Decides which app a write really belongs to.
///
/// fs_usage names the process that issued the I/O, which is often not the program that produced
/// the data. launchd syncs every program's pending writes every 30 seconds and gets charged for
/// them, so its name alone says nothing useful. For those writes this looks at the file instead:
/// first, who was seen writing that file directly this session; then, what its path implies.
public enum Attribution {
    public static let metadataOwner = "Filesystem metadata"
    public static let unattributedOwner = "Unattributed (flushed by launchd)"

    /// Processes that push other programs' pending data to disk, and get charged for it.
    private static let flushers: Set<String> = ["launchd", "kernel_task", "sync"]

    public static func isFlusher(_ process: String) -> Bool {
        flushers.contains(process)
    }

    public static func owner(process: String, path: String, seenWriter: String?) -> String {
        if !isFlusher(process) {
            return displayName(forProcess: process)
        }
        if path.isEmpty { return metadataOwner }
        if path.hasSuffix("com.apple.xpc.launchd/launchd.log") { return "launchd (own log)" }
        if let seenWriter { return displayName(forProcess: seenWriter) }
        return guessOwner(fromPath: path) ?? unattributedOwner
    }

    /// Merges a program's helper processes into one row.
    public static func displayName(forProcess process: String) -> String {
        if process.hasSuffix(" Helper") { return String(process.dropLast(" Helper".count)) }
        if let range = process.range(of: " Helper (") { return String(process[..<range.lowerBound]) }
        return process
    }

    public static func guessOwner(fromPath path: String) -> String? {
        for (needle, owner) in knownLocations where path.contains(needle) {
            return owner
        }
        for marker in ["/Application Support/", "/Library/Caches/", "/Library/Logs/", "/Library/HTTPStorages/"] {
            if let name = component(after: marker, in: path) { return friendly(name) }
        }
        if let app = component(after: "/Applications/", in: path), app.hasSuffix(".app") {
            return String(app.dropLast(4))
        }
        for marker in ["/Library/Containers/", "/Library/Group Containers/"] {
            if let name = component(after: marker, in: path), !isUUID(name) { return friendly(name) }
        }
        return nil
    }

    private static let knownLocations: [(String, String)] = [
        ("mozilla-temp", "firefox"),
        ("/Firefox/", "firefox"),
        ("/var/db/diagnostics/", "logd (system log)"),
        ("/var/db/uuidtext/", "logd (system log)"),
        ("Spotlight", "Spotlight"),
        ("/Library/Metadata/CoreSpotlight/", "Spotlight"),
        ("/Library/Biome/", "Biome"),
        ("/var/db/biome/", "Biome"),
        ("searchpartyd", "searchpartyd"),
        ("/Library/Caches/CloudKit/", "cloudd"),
        ("/Library/DuetExpertCenter/", "duetexpertd"),
        ("/Application Support/Knowledge/", "knowledge-agent"),
        ("/Library/IntelligencePlatform/", "knowledge-agent"),
        ("/Library/PersonalizationPortrait/", "knowledge-agent"),
        ("com.apple.nsurlsessiond", "nsurlsessiond"),
        ("/var/db/systemstats/", "systemstats"),
        ("/var/db/analyticsd/", "analyticsd"),
        ("/Library/Keychains/", "secd (keychain)"),
        ("com.apple.Safari.SafeBrowsing", "Safari SafeBrowsing"),
        ("com.apple.geod", "geod"),
        ("/var/log/", "System logs"),
    ]

    private static func component(after marker: String, in path: String) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex else { return nil }
        return String(rest[..<slash])
    }

    private static func friendly(_ name: String) -> String {
        name.hasPrefix("group.") ? String(name.dropFirst(6)) : name
    }

    private static func isUUID(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }
}
