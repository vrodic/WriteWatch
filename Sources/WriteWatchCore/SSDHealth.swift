import Foundation

/// An NVMe SMART health log, independent of how it was read.
public struct SSDHealth: Sendable {
    public enum Verdict: Equatable, Sendable {
        case healthy
        case warning(String)
        case critical(String)
    }

    /// NVMe reports read and write totals in units of 1000 sectors of 512 bytes.
    public static let dataUnitBytes = 512_000.0

    public var model: String
    public var firmware: String
    public var capacityBytes: UInt64
    public var criticalWarning: UInt8
    public var temperatureCelsius: Int
    public var availableSpare: Int
    public var availableSpareThreshold: Int
    public var percentageUsed: Int
    public var bytesRead: Double
    public var bytesWritten: Double
    public var powerCycles: UInt64
    public var powerOnHours: UInt64
    public var unsafeShutdowns: UInt64
    public var mediaErrors: UInt64
    public var errorLogEntries: UInt64

    public init(
        model: String, firmware: String, capacityBytes: UInt64, criticalWarning: UInt8,
        temperatureCelsius: Int, availableSpare: Int, availableSpareThreshold: Int,
        percentageUsed: Int, bytesRead: Double, bytesWritten: Double, powerCycles: UInt64,
        powerOnHours: UInt64, unsafeShutdowns: UInt64, mediaErrors: UInt64, errorLogEntries: UInt64
    ) {
        self.model = model
        self.firmware = firmware
        self.capacityBytes = capacityBytes
        self.criticalWarning = criticalWarning
        self.temperatureCelsius = temperatureCelsius
        self.availableSpare = availableSpare
        self.availableSpareThreshold = availableSpareThreshold
        self.percentageUsed = percentageUsed
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
        self.errorLogEntries = errorLogEntries
    }

    public var verdict: Verdict {
        if criticalWarning != 0 {
            return .critical("The drive is reporting a critical warning (0x\(String(criticalWarning, radix: 16))).")
        }
        if availableSpare < availableSpareThreshold {
            return .critical("Spare capacity is below the drive's safety threshold.")
        }
        if mediaErrors > 0 {
            return .critical("The drive has recorded \(mediaErrors) unrecovered media errors.")
        }
        if percentageUsed >= 100 {
            return .warning("The drive has used all of its rated endurance.")
        }
        if percentageUsed >= 90 {
            return .warning("The drive has used \(percentageUsed)% of its rated endurance.")
        }
        return .healthy
    }

    public var averageBytesWrittenPerDay: Double? {
        guard powerOnHours >= 24 else { return nil }
        return bytesWritten / (Double(powerOnHours) / 24)
    }

    /// Rough total the drive might accept, scaled from wear so far. The reported percentage is a
    /// whole number, so this is only offered once wear is high enough to mean something.
    public var estimatedEnduranceBytes: Double? {
        guard percentageUsed >= 5 else { return nil }
        return bytesWritten * 100 / Double(percentageUsed)
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(0, bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) B" }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }

    public static func string(_ bytes: Int) -> String {
        string(Double(bytes))
    }
}
