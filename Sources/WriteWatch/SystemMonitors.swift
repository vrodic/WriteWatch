import CNVMeSMART
import Darwin
import Foundation
import IOKit
import WriteWatchCore

/// Cumulative bytes transferred by the internal NVMe drive, from IOKit. Needs no privileges.
final class DiskCounters {
    private var driver: io_registry_entry_t = IO_OBJECT_NULL

    init() {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
            == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            var isInternalNVMe = false
            if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
                let capable = IORegistryEntryCreateCFProperty(
                    parent, "NVMe SMART Capable" as CFString, kCFAllocatorDefault, 0)
                isInternalNVMe = (capable?.takeRetainedValue() as? Bool) == true
                IOObjectRelease(parent)
            }
            if isInternalNVMe, driver == IO_OBJECT_NULL {
                driver = entry
            } else {
                IOObjectRelease(entry)
            }
        }
    }

    deinit {
        if driver != IO_OBJECT_NULL { IOObjectRelease(driver) }
    }

    func bytesWritten() -> UInt64? {
        guard driver != IO_OBJECT_NULL,
            let value = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0),
            let statistics = value.takeRetainedValue() as? [String: Any],
            let bytes = statistics["Bytes (Write)"] as? NSNumber
        else { return nil }
        return bytes.uint64Value
    }
}

private func usage(of pid: pid_t) -> rusage_info_v2? {
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
        }
    }
    return result == 0 ? info : nil
}

/// This app's own footprint, shown in the UI so the no-disk-writes rule can be checked directly.
enum OwnUsage {
    static func read() -> (diskBytesWritten: UInt64, memoryBytes: UInt64) {
        guard let info = usage(of: getpid()) else { return (0, 0) }
        return (info.ri_diskio_byteswritten, info.ri_phys_footprint)
    }
}

/// Per-process write deltas for processes this user may inspect. Used only without root access.
final class ProcessSampler {
    private var previous: [pid_t: UInt64] = [:]

    /// The first call only sets the baseline, so nothing written before the capture is counted.
    func sample(_ report: (String, Int) -> Void, isBaseline: Bool = false) {
        var pids = [pid_t](repeating: 0, count: 8192)
        let size = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard size > 0 else { return }

        var current: [pid_t: UInt64] = [:]
        for pid in pids.prefix(Int(size)) where pid > 0 {
            guard let info = usage(of: pid) else { continue }
            let written = info.ri_diskio_byteswritten
            current[pid] = written
            guard !isBaseline else { continue }
            // A process first seen now was started during the capture, so all of it counts.
            let delta = written - min(previous[pid] ?? 0, written)
            if delta > 0 { report(Self.name(of: pid), Int(delta)) }
        }
        previous = current
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : "pid \(pid)"
    }
}

enum SMARTReader {
    struct Failure: Error {
        let message: String
    }

    static func read() -> Result<SSDHealth, Failure> {
        var report = ww_smart_report()
        var error = [CChar](repeating: 0, count: 256)
        guard ww_read_smart(&report, &error, UInt(error.count)) == 0 else {
            return .failure(Failure(message: String(cString: error)))
        }
        let model = withUnsafeBytes(of: &report.model) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let firmware = withUnsafeBytes(of: &report.firmware) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        return .success(
            SSDHealth(
                model: model.isEmpty ? "NVMe SSD" : model,
                firmware: firmware,
                capacityBytes: report.capacity_bytes,
                criticalWarning: report.critical_warning,
                temperatureCelsius: Int(report.temperature_kelvin) - 273,
                availableSpare: Int(report.available_spare),
                availableSpareThreshold: Int(report.available_spare_threshold),
                percentageUsed: Int(report.percentage_used),
                bytesRead: Double(report.data_units_read) * SSDHealth.dataUnitBytes,
                bytesWritten: Double(report.data_units_written) * SSDHealth.dataUnitBytes,
                powerCycles: report.power_cycles,
                powerOnHours: report.power_on_hours,
                unsafeShutdowns: report.unsafe_shutdowns,
                mediaErrors: report.media_errors,
                errorLogEntries: report.error_log_entries
            ))
    }
}
