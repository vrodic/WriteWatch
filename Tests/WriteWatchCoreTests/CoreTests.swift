import Foundation
import XCTest

@testable import WriteWatchCore

final class ParserTests: XCTestCase {
    func testParsesWriteWithFlagsAndNormalizesDataVolumePath() throws {
        let line = "16:10:39.484469  WrData[AT3]  D=0x0295f7ca  B=0x3000  /dev/disk3s5  "
            + "/System/Volumes/Data/private/var/db/x.tracev3  0.000101 W launchd.1815995"
        let write = try XCTUnwrap(FSUsageParser.parse(line))
        XCTAssertEqual(write.timestamp, "16:10:39.484469")
        XCTAssertEqual(write.operation, "WrData")
        XCTAssertEqual(write.flags, "AT3")
        XCTAssertEqual(write.bytes, 0x3000)
        XCTAssertEqual(write.path, "/private/var/db/x.tracev3")
        XCTAssertEqual(write.process, "launchd")
        XCTAssertEqual(write.threadID, "1815995")
    }

    func testHandlesSpacesInPathAndProcessName() throws {
        let line = "16:10:26.236514    WrData[A]       D=0x02f06abf  B=0xb000   /dev/disk3s5  "
            + "/Users/v/Library/Application Support/Claude/a b.log       0.000200 W Claude Helper.42  "
        let write = try XCTUnwrap(FSUsageParser.parse(line))
        XCTAssertEqual(write.path, "/Users/v/Library/Application Support/Claude/a b.log")
        XCTAssertEqual(write.process, "Claude Helper")
        XCTAssertEqual(write.threadID, "42")
    }

    func testMetadataWriteHasEmptyPath() throws {
        let line = "16:10:39.1  WrMeta[AT1P]  D=0x1  B=0x1000  /dev/disk3s5    0.000040 W kernel_task.9"
        let write = try XCTUnwrap(FSUsageParser.parse(line))
        XCTAssertEqual(write.path, "")
        XCTAssertEqual(write.process, "kernel_task")
    }

    func testIgnoresReadsNullDeviceAndNoise() {
        XCTAssertNil(FSUsageParser.parse("16:10:21.0  RdData[A]  D=0x1  B=0x1000  /dev/disk3s5  /a  0.000100 W x.1"))
        XCTAssertNil(FSUsageParser.parse("16:10:21.0  WrData[S]  D=0x20a  B=0x49  /dev/NOTFOUND  /dev/null  0.000100 x.1"))
        XCTAssertNil(FSUsageParser.parse("fs_usage: must be run as root"))
        XCTAssertNil(FSUsageParser.parse(""))
    }
}

final class AttributionTests: XCTestCase {
    func testDirectWriterKeepsItsOwnName() {
        XCTAssertEqual(Attribution.owner(process: "firefox", path: "/a", seenWriter: "firefox"), "firefox")
        XCTAssertEqual(Attribution.owner(process: "Claude Helper", path: "/a", seenWriter: nil), "Claude")
    }

    func testLaunchdFlushGoesToSeenWriterThenPathGuess() {
        XCTAssertEqual(Attribution.owner(process: "launchd", path: "/x", seenWriter: "biomesyncd"), "biomesyncd")
        XCTAssertEqual(
            Attribution.owner(
                process: "launchd",
                path: "/Users/v/Library/Application Support/Firefox/Profiles/p/places.sqlite-wal",
                seenWriter: nil),
            "firefox")
        XCTAssertEqual(
            Attribution.owner(process: "launchd", path: "/private/var/db/diagnostics/Persist/1.tracev3", seenWriter: nil),
            "logd (system log)")
        XCTAssertEqual(Attribution.owner(process: "launchd", path: "/weird", seenWriter: nil), Attribution.unattributedOwner)
    }

    func testLaunchdOwnLogAndMetadata() {
        XCTAssertEqual(
            Attribution.owner(process: "launchd", path: "/private/var/log/com.apple.xpc.launchd/launchd.log", seenWriter: nil),
            "launchd (own log)")
        XCTAssertEqual(Attribution.owner(process: "kernel_task", path: "", seenWriter: nil), Attribution.metadataOwner)
    }
}

final class StoreTests: XCTestCase {
    private func write(_ bytes: Int, _ process: String = "app", path: String = "/f", time: String = "t") -> RawWrite {
        RawWrite(timestamp: time, operation: "WrData", flags: "A", bytes: bytes, path: path, process: process, threadID: "1")
    }

    func testRanksAppsAndFilesAndLogsOnlyLargeWrites() {
        let store = CaptureStore(threshold: 100)
        store.ingest(write(50, "a", path: "/small"))
        store.ingest(write(500, "b", path: "/big"))
        let snapshot = store.snapshot(top: 10)
        XCTAssertEqual(snapshot.apps.map(\.name), ["b", "a"])
        XCTAssertEqual(snapshot.files.map(\.path), ["/big", "/small"])
        XCTAssertEqual(snapshot.tracedBytes, 550)
        XCTAssertEqual(snapshot.logCount, 1)
    }

    func testLaunchdFlushIsCreditedToEarlierDirectWriter() {
        let store = CaptureStore(threshold: 1)
        store.ingest(write(10, "firefox", path: "/db"))
        store.ingest(write(90, "launchd", path: "/db"))
        let snapshot = store.snapshot(top: 10)
        XCTAssertEqual(snapshot.apps.first?.name, "firefox")
        XCTAssertEqual(snapshot.apps.first?.bytes, 100)
        XCTAssertEqual(snapshot.flushedBytes, 90)
    }

    func testCountsOwnFilesFlushedByLaunchd() {
        let store = CaptureStore(threshold: 1)
        store.ingest(write(40, "launchd", path: "/var/folders/x/C/local.writewatch.app/com.apple.metal/a.list"))
        store.ingest(write(99, "launchd", path: "/other/file"))
        XCTAssertEqual(store.snapshot(top: 1).ownFlushedBytes, 40)
    }

    func testLogRingKeepsNewestAndCountsDropped() {
        let store = CaptureStore(threshold: 1, logCapacity: 3)
        for i in 1...5 { store.ingest(write(i, time: "\(i)")) }
        XCTAssertEqual(store.recentLog(limit: 10).map(\.write.timestamp), ["5", "4", "3"])
        XCTAssertEqual(store.snapshot(top: 1).droppedLogEntries, 2)
        let csv = String(decoding: store.logCSV(), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(csv.count, 4)
        XCTAssertTrue(csv[1].hasPrefix("\"3\""))
    }

    func testFileTableStaysBoundedAndKeepsBiggest() {
        let store = CaptureStore(threshold: 1000, fileCapacity: 10)
        store.ingest(write(999, path: "/biggest"))
        for i in 0..<100 { store.ingest(write(1, path: "/f\(i)")) }
        let snapshot = store.snapshot(top: 100)
        XCTAssertLessThanOrEqual(snapshot.files.count, 10)
        XCTAssertEqual(snapshot.files.first?.path, "/biggest")
        XCTAssertEqual(snapshot.tracedBytes, 1099)
    }

    func testCSVEscapesQuotes() {
        let store = CaptureStore(threshold: 1)
        store.ingest(write(5, path: "/a\"b,c"))
        XCTAssertTrue(String(decoding: store.logCSV(), as: UTF8.self).contains("\"/a\"\"b,c\""))
    }

    func testResetClearsEverything() {
        let store = CaptureStore(threshold: 1)
        store.ingest(write(5))
        store.reset()
        let snapshot = store.snapshot(top: 5)
        XCTAssertEqual(snapshot.tracedBytes, 0)
        XCTAssertTrue(snapshot.apps.isEmpty)
        XCTAssertEqual(snapshot.logCount, 0)
    }
}

final class HealthTests: XCTestCase {
    private func health(
        critical: UInt8 = 0, spare: Int = 100, used: Int = 2, media: UInt64 = 0, written: Double = 1e12, hours: UInt64 = 1000
    ) -> SSDHealth {
        SSDHealth(
            model: "m", firmware: "f", capacityBytes: 1, criticalWarning: critical, temperatureCelsius: 30,
            availableSpare: spare, availableSpareThreshold: 10, percentageUsed: used, bytesRead: 0,
            bytesWritten: written, powerCycles: 1, powerOnHours: hours, unsafeShutdowns: 0,
            mediaErrors: media, errorLogEntries: 0)
    }

    func testVerdicts() {
        XCTAssertEqual(health().verdict, .healthy)
        if case .critical = health(critical: 1).verdict {} else { XCTFail() }
        if case .critical = health(spare: 5).verdict {} else { XCTFail() }
        if case .critical = health(media: 3).verdict {} else { XCTFail() }
        if case .warning = health(used: 95).verdict {} else { XCTFail() }
    }

    func testEstimatesRequireEnoughData() {
        XCTAssertNil(health(used: 2).estimatedEnduranceBytes)
        XCTAssertEqual(health(used: 10, written: 1e12).estimatedEnduranceBytes, 1e13)
        XCTAssertNil(health(hours: 10).averageBytesWrittenPerDay)
        XCTAssertEqual(health(written: 24e9, hours: 24).averageBytesWrittenPerDay, 24e9)
    }

    func testByteFormat() {
        XCTAssertEqual(ByteFormat.string(512), "512 B")
        XCTAssertEqual(ByteFormat.string(1_500_000), "1.5 MB")
        XCTAssertEqual(ByteFormat.string(250_000_000_000), "250 GB")
    }
}

final class RealCaptureTests: XCTestCase {
    /// Set WW_CAPTURE to a plain-text fs_usage capture to check parsing on real data.
    func testRealCaptureIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["WW_CAPTURE"] else {
            throw XCTSkip("WW_CAPTURE not set")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let store = CaptureStore(threshold: 64 * 1024)
        var candidates = 0
        var parsed = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count > 1, fields[1].hasPrefix("Wr") || fields[1].hasPrefix("PgOut"),
                !line.contains("/dev/NOTFOUND")
            else { continue }
            candidates += 1
            if let write = FSUsageParser.parse(String(line)) {
                parsed += 1
                store.ingest(write)
            }
        }
        let snapshot = store.snapshot(top: 12)
        print("REAL candidates=\(candidates) parsed=\(parsed) bytes=\(ByteFormat.string(snapshot.tracedBytes)) flushed=\(ByteFormat.string(snapshot.flushedBytes))")
        for app in snapshot.apps { print("REAL app \(ByteFormat.string(app.bytes)) \(app.name)") }
        XCTAssertEqual(parsed, candidates)
    }
}
