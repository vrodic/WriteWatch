import Foundation

public struct LogEntry: Sendable {
    public let write: RawWrite
    public let owner: String
    public let onRAMDisk: Bool
}

public struct RankedApp: Sendable {
    public let name: String
    public let bytes: Int
    public let writes: Int
}

public struct RankedFile: Sendable {
    public let path: String
    public let owner: String
    public let bytes: Int
    public let writes: Int
}

public struct CaptureSnapshot: Sendable {
    /// Writes to real storage. RAM disk writes are kept apart, since they never reach the SSD.
    public let apps: [RankedApp]
    public let files: [RankedFile]
    public let ramApps: [RankedApp]
    public let ramFiles: [RankedFile]
    /// Everything traced, including RAM disks.
    public let tracedBytes: Int
    public let ramDiskBytes: Int
    public let writeCount: Int
    public let flushedBytes: Int
    public let logCount: Int
    public let droppedLogEntries: Int
    /// This app's own files as flushed by another process, which its write counter can't see.
    public let ownFlushedBytes: Int
}

/// Everything a capture knows, held only in RAM and bounded so a long capture cannot exhaust it.
/// All methods are thread-safe: the socket thread ingests while the main thread reads.
public final class CaptureStore: @unchecked Sendable {
    public static let defaultLogCapacity = 200_000
    public static let defaultFileCapacity = 50_000

    private struct Tally {
        var bytes = 0
        var writes = 0
    }

    private struct FileTally {
        var bytes = 0
        var writes = 0
        var owner = ""
    }

    /// Per-app and per-file totals for one kind of storage.
    private struct Ledger {
        var apps: [String: Tally] = [:]
        var files: [String: FileTally] = [:]

        func rankedApps(top: Int) -> [RankedApp] {
            Array(
                apps
                    .map { RankedApp(name: $0.key, bytes: $0.value.bytes, writes: $0.value.writes) }
                    .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
                    .prefix(top))
        }

        func rankedFiles(top: Int) -> [RankedFile] {
            Array(
                files
                    .map { RankedFile(path: $0.key, owner: $0.value.owner, bytes: $0.value.bytes, writes: $0.value.writes) }
                    .sorted { ($0.bytes, $1.path) > ($1.bytes, $0.path) }
                    .prefix(top))
        }
    }

    private let lock = NSLock()
    private let logCapacity: Int
    private let fileCapacity: Int

    private var disk = Ledger()
    private var ram = Ledger()
    private var directWriters: [String: String] = [:]
    private var log: [LogEntry] = []
    private var logStart = 0
    private var droppedLogEntries = 0
    private var droppedFileBytes = 0
    private var tracedBytes = 0
    private var ramDiskBytes = 0
    private var writeCount = 0
    private var flushedBytes = 0
    private var ownFlushedBytes = 0
    private var threshold: Int

    public init(
        threshold: Int = 64 * 1024,
        logCapacity: Int = CaptureStore.defaultLogCapacity,
        fileCapacity: Int = CaptureStore.defaultFileCapacity
    ) {
        self.threshold = threshold
        self.logCapacity = max(1, logCapacity)
        self.fileCapacity = max(2, fileCapacity)
    }

    /// Applies to writes from now on. Entries already logged stay.
    public func setThreshold(_ bytes: Int) {
        lock.withLock { threshold = bytes }
    }

    public func ingest(_ write: RawWrite, onRAMDisk: Bool = false) {
        lock.lock()
        defer { lock.unlock() }

        let isFlusher = Attribution.isFlusher(write.process)
        if !isFlusher, !write.path.isEmpty {
            directWriters[write.path] = write.process
        }
        let owner = Attribution.owner(
            process: write.process, path: write.path, seenWriter: directWriters[write.path])

        tracedBytes += write.bytes
        writeCount += 1
        if onRAMDisk { ramDiskBytes += write.bytes }
        if write.process == "launchd" { flushedBytes += write.bytes }
        if isFlusher, write.path.contains("local.writewatch.app") { ownFlushedBytes += write.bytes }

        if onRAMDisk {
            record(write, owner: owner, in: &ram)
        } else {
            record(write, owner: owner, in: &disk)
        }

        if write.bytes >= threshold {
            append(LogEntry(write: write, owner: owner, onRAMDisk: onRAMDisk))
        }
    }

    private func record(_ write: RawWrite, owner: String, in ledger: inout Ledger) {
        ledger.apps[owner, default: Tally()].bytes += write.bytes
        ledger.apps[owner, default: Tally()].writes += 1

        guard !write.path.isEmpty else { return }
        var file = ledger.files[write.path] ?? FileTally()
        file.bytes += write.bytes
        file.writes += 1
        file.owner = owner
        ledger.files[write.path] = file
        if ledger.files.count > fileCapacity { prune(&ledger) }
    }

    /// Without root, per-process counters are all that is available: no file or device detail, so
    /// RAM disk writes can't be told apart here.
    public func addProcessBytes(name: String, bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let owner = Attribution.displayName(forProcess: name)
        disk.apps[owner, default: Tally()].bytes += bytes
        disk.apps[owner, default: Tally()].writes += 1
        tracedBytes += bytes
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        disk = Ledger()
        ram = Ledger()
        directWriters = [:]
        log = []
        logStart = 0
        droppedLogEntries = 0
        droppedFileBytes = 0
        tracedBytes = 0
        ramDiskBytes = 0
        writeCount = 0
        flushedBytes = 0
        ownFlushedBytes = 0
    }

    public func snapshot(top: Int) -> CaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CaptureSnapshot(
            apps: disk.rankedApps(top: top),
            files: disk.rankedFiles(top: top),
            ramApps: ram.rankedApps(top: top),
            ramFiles: ram.rankedFiles(top: top),
            tracedBytes: tracedBytes,
            ramDiskBytes: ramDiskBytes,
            writeCount: writeCount,
            flushedBytes: flushedBytes,
            logCount: log.count,
            droppedLogEntries: droppedLogEntries,
            ownFlushedBytes: ownFlushedBytes
        )
    }

    /// Newest first.
    public func recentLog(limit: Int) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return orderedLog().suffix(limit).reversed()
    }

    public func logCSV() -> Data {
        lock.lock()
        defer { lock.unlock() }
        var out = "time,bytes,storage,device,app,process,thread,operation,flags,path\n"
        for entry in orderedLog() {
            let write = entry.write
            let fields = [
                write.timestamp, String(write.bytes), Self.storageName(onRAMDisk: entry.onRAMDisk), write.device,
                entry.owner, write.process, write.threadID, write.operation, write.flags, write.path,
            ]
            out += fields.map(Self.csvField).joined(separator: ",") + "\n"
        }
        return Data(out.utf8)
    }

    public func totalsCSV() -> Data {
        lock.lock()
        defer { lock.unlock() }
        var out = "kind,storage,name,app,bytes,writes\n"
        for (ledger, onRAMDisk) in [(disk, false), (ram, true)] {
            let storage = Self.storageName(onRAMDisk: onRAMDisk)
            for (name, tally) in ledger.apps.sorted(by: { $0.value.bytes > $1.value.bytes }) {
                out += ["app", storage, name, name, String(tally.bytes), String(tally.writes)]
                    .map(Self.csvField).joined(separator: ",") + "\n"
            }
            for (path, tally) in ledger.files.sorted(by: { $0.value.bytes > $1.value.bytes }) {
                out += ["file", storage, path, tally.owner, String(tally.bytes), String(tally.writes)]
                    .map(Self.csvField).joined(separator: ",") + "\n"
            }
        }
        if droppedFileBytes > 0 {
            out += ["file", "", "(smaller files dropped to bound memory)", "", String(droppedFileBytes), ""]
                .map(Self.csvField).joined(separator: ",") + "\n"
        }
        return Data(out.utf8)
    }

    private static func storageName(onRAMDisk: Bool) -> String {
        onRAMDisk ? "RAM disk" : "Disk"
    }

    private func append(_ entry: LogEntry) {
        if log.count < logCapacity {
            log.append(entry)
        } else {
            log[logStart] = entry
            logStart = (logStart + 1) % logCapacity
            droppedLogEntries += 1
        }
    }

    private func orderedLog() -> ArraySlice<LogEntry> {
        logStart == 0 ? log[...] : (log[logStart...] + log[..<logStart])[...]
    }

    /// Forgets the smaller half of a file table. Anything big enough to rank survives.
    private func prune(_ ledger: inout Ledger) {
        let keep = ledger.files.sorted { $0.value.bytes > $1.value.bytes }.prefix(fileCapacity / 2)
        let kept = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        for (path, tally) in ledger.files where kept[path] == nil {
            droppedFileBytes += tally.bytes
            directWriters[path] = nil
        }
        ledger.files = kept
    }

    private static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
