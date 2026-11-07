/// One physical write reported by `fs_usage -w -f diskio`.
public struct RawWrite: Equatable, Sendable {
    public var timestamp: String
    public var operation: String
    public var flags: String
    public var bytes: Int
    public var path: String
    public var process: String
    public var threadID: String

    public init(
        timestamp: String, operation: String, flags: String, bytes: Int,
        path: String, process: String, threadID: String
    ) {
        self.timestamp = timestamp
        self.operation = operation
        self.flags = flags
        self.bytes = bytes
        self.path = path
        self.process = process
        self.threadID = threadID
    }
}

/// Parses fs_usage lines without building a String per line, since heavy I/O produces many
/// thousands of lines a second and most of them are reads we immediately discard.
///
///     16:10:39.484  WrData[AT3]  D=0x0295f7ca  B=0x3000  /dev/disk3s5  /path  0.000101 W proc.123
public enum FSUsageParser {
    private static let space = UInt8(ascii: " ")
    private static let dot = UInt8(ascii: ".")
    private static let dataVolumePrefix = "/System/Volumes/Data/"

    public static func parse(_ line: UnsafeBufferPointer<UInt8>) -> RawWrite? {
        var end = line.count
        while end > 0, isBlank(line[end - 1]) { end -= 1 }

        var index = 0
        let timestampEnd = tokenEnd(line, from: index, end: end)
        guard timestampEnd > 0, timestampEnd < end else { return nil }

        index = skipBlanks(line, from: timestampEnd, end: end)
        let operationStart = index
        let operationEnd = tokenEnd(line, from: index, end: end)
        guard isWrite(line, start: operationStart, end: operationEnd) else { return nil }

        guard let bytesField = find(line, needle: " B=0x", from: operationEnd, end: end) else { return nil }
        index = bytesField + 5
        var bytes = 0
        while index < end, let digit = hexValue(line[index]) {
            bytes = bytes &* 16 &+ digit
            index += 1
        }

        index = skipBlanks(line, from: index, end: end)
        let deviceEnd = tokenEnd(line, from: index, end: end)
        // Writes to /dev/null and similar never reach a disk.
        if starts(line, with: "/dev/NOTFOUND", at: index) { return nil }

        guard let elapsed = findElapsedToken(line, from: deviceEnd, end: end) else { return nil }

        var processStart = skipBlanks(line, from: elapsed.end, end: end)
        if processStart + 1 < end, line[processStart] == UInt8(ascii: "W"), isBlank(line[processStart + 1]) {
            processStart = skipBlanks(line, from: processStart + 1, end: end)
        }
        guard processStart < end else { return nil }

        // The process name can contain spaces ("Claude Helper"), so split on the final dot.
        var separator = end - 1
        while separator > processStart, line[separator] != dot { separator -= 1 }
        guard separator > processStart else { return nil }

        var pathStart = skipBlanks(line, from: deviceEnd, end: elapsed.start)
        var pathEnd = elapsed.start
        while pathEnd > pathStart, isBlank(line[pathEnd - 1]) { pathEnd -= 1 }
        if pathStart > pathEnd { pathStart = pathEnd }

        let operationToken = text(line, operationStart, operationEnd)
        var operation = operationToken
        var flags = ""
        if let bracket = operationToken.firstIndex(of: "[") {
            operation = String(operationToken[..<bracket])
            flags = operationToken[bracket...].trimmingBrackets()
        }

        return RawWrite(
            timestamp: text(line, 0, timestampEnd),
            operation: operation,
            flags: flags,
            bytes: bytes,
            path: normalize(path: text(line, pathStart, pathEnd)),
            process: text(line, processStart, separator),
            threadID: text(line, separator + 1, end)
        )
    }

    public static func parse(_ line: String) -> RawWrite? {
        var copy = line
        return copy.withUTF8 { parse($0) }
    }

    /// Reports the same file under one name, however fs_usage happened to spell it.
    public static func normalize(path: String) -> String {
        if path.hasPrefix(dataVolumePrefix) {
            return "/" + path.dropFirst(dataVolumePrefix.count)
        }
        return path
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == space || byte == 9 || byte == 13
    }

    private static func tokenEnd(_ line: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        var index = start
        while index < end, !isBlank(line[index]) { index += 1 }
        return index
    }

    private static func skipBlanks(_ line: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        var index = start
        while index < end, isBlank(line[index]) { index += 1 }
        return index
    }

    private static func isWrite(_ line: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> Bool {
        guard end - start >= 2 else { return false }
        if line[start] == UInt8(ascii: "W"), line[start + 1] == UInt8(ascii: "r") { return true }
        return starts(line, with: "PgOut", at: start)
    }

    private static func starts(_ line: UnsafeBufferPointer<UInt8>, with text: StaticString, at start: Int) -> Bool {
        let count = text.utf8CodeUnitCount
        guard start + count <= line.count else { return false }
        let needle = text.utf8Start
        for offset in 0..<count where line[start + offset] != needle[offset] { return false }
        return true
    }

    private static func find(
        _ line: UnsafeBufferPointer<UInt8>, needle: StaticString, from start: Int, end: Int
    ) -> Int? {
        let count = needle.utf8CodeUnitCount
        guard end >= count else { return nil }
        var index = start
        while index <= end - count {
            if starts(line, with: needle, at: index) { return index }
            index += 1
        }
        return nil
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 48...57: return Int(byte) - 48
        case 97...102: return Int(byte) - 87
        case 65...70: return Int(byte) - 55
        default: return nil
        }
    }

    /// Finds the elapsed-time column (`0.000101`) by scanning tokens from the right. Paths and
    /// process names can both contain spaces, so this column is the only reliable divider.
    private static func findElapsedToken(
        _ line: UnsafeBufferPointer<UInt8>, from lowerBound: Int, end: Int
    ) -> (start: Int, end: Int)? {
        var tokenEnd = end
        while tokenEnd > lowerBound {
            while tokenEnd > lowerBound, isBlank(line[tokenEnd - 1]) { tokenEnd -= 1 }
            var tokenStart = tokenEnd
            while tokenStart > lowerBound, !isBlank(line[tokenStart - 1]) { tokenStart -= 1 }
            if tokenEnd > tokenStart, isElapsed(line, start: tokenStart, end: tokenEnd) {
                return (tokenStart, tokenEnd)
            }
            tokenEnd = tokenStart
        }
        return nil
    }

    private static func isElapsed(_ line: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> Bool {
        // At least one integer digit, a dot, then exactly six decimals.
        guard end - start >= 8, line[end - 7] == dot else { return false }
        for index in start..<end where index != end - 7 {
            guard line[index] >= 48, line[index] <= 57 else { return false }
        }
        return true
    }

    private static func text(_ line: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: line[start..<end]), as: UTF8.self)
    }
}

private extension Substring {
    func trimmingBrackets() -> String {
        var value = self
        if value.hasPrefix("[") { value.removeFirst() }
        if value.hasSuffix("]") { value.removeLast() }
        return String(value)
    }
}
