import AppKit
import Darwin
import WriteWatchCore

/// The app's end of the link to the root helper.
///
/// The helper is launched through the standard macOS administrator prompt and connects back over
/// loopback. TCP keeps this free of any socket or pipe file on disk, and when the app exits for
/// any reason the connection drops and the helper stops the trace and exits.
final class HelperConnection: @unchecked Sendable {
    enum LaunchResult {
        case launched
        case cancelled
        case failed(String)
    }

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onWrite: ((RawWrite) -> Void)?

    private let token: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var connectionFD: Int32 = -1
    private var isCancelled = false
    private(set) var port: UInt16 = 0

    init() {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Binds a random loopback port and waits on a background thread for the helper.
    func listen() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                Darwin.bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            return false
        }
        port = UInt16(bigEndian: address.sin_port)
        listenFD = fd
        Thread.detachNewThread { [self] in acceptAndRead() }
        return true
    }

    /// Shows the administrator prompt. Must be called on the main thread, and blocks until answered.
    func launchHelper(executable: String, memoryLimitMB: Int? = nil) -> LaunchResult {
        let quotedPath = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // All three streams must be detached, or the script waits on the background helper.
        let limit = memoryLimitMB.map { " \($0)" } ?? ""
        let command = "\(quotedPath) \(port) \(token)\(limit) </dev/null >/dev/null 2>&1 &"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = "WriteWatch needs administrator access to see which apps and files are being written. "
            + "Captures stay in memory until you save them."
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failed("Could not prepare the permission request.")
        }
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .launched }
        if errorInfo[NSAppleScript.errorNumber] as? Int == -128 { return .cancelled }
        return .failed(errorInfo[NSAppleScript.errorMessage] as? String ?? "The permission request failed.")
    }

    func startTrace() { send("S") }
    func stopTrace() { send("X") }

    /// Stops listening and drops any connection, which makes the helper exit.
    func disconnect() {
        lock.lock()
        isCancelled = true
        let connection = connectionFD
        lock.unlock()
        if connection >= 0 { shutdown(connection, SHUT_RDWR) }
    }

    private func send(_ text: String) {
        lock.lock()
        let fd = connectionFD
        lock.unlock()
        guard fd >= 0 else { return }
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    private func acceptAndRead() {
        defer { close(listenFD) }
        while true {
            lock.lock()
            let cancelled = isCancelled
            lock.unlock()
            if cancelled { return }

            var descriptor = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 500) > 0 else { continue }
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { continue }

            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

            guard verifyToken(fd) else {
                close(fd)
                continue
            }

            lock.lock()
            connectionFD = fd
            lock.unlock()
            DispatchQueue.main.async { self.onConnected?() }

            readLoop(fd)

            lock.lock()
            connectionFD = -1
            lock.unlock()
            close(fd)
            DispatchQueue.main.async { self.onDisconnected?() }
            return
        }
    }

    private func verifyToken(_ fd: Int32) -> Bool {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        defer {
            var none = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        }
        var received: [UInt8] = []
        var byte: UInt8 = 0
        while received.count <= token.utf8.count {
            guard read(fd, &byte, 1) == 1 else { return false }
            if byte == UInt8(ascii: "\n") { break }
            received.append(byte)
        }
        return received == Array(token.utf8)
    }

    private func readLoop(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        var pending = 0  // Bytes of an incomplete line kept at the start of the chunk.
        while true {
            if pending == chunk.count { pending = 0 }  // A line this long is not fs_usage output.
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress! + pending, $0.count - pending) }
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return }
            let available = pending + count
            pending = chunk.withUnsafeMutableBufferPointer { buffer -> Int in
                let base = UnsafeBufferPointer(buffer)
                var start = 0
                var index = 0
                while index < available {
                    if base[index] == 10 {
                        handleLine(UnsafeBufferPointer(rebasing: base[start..<index]))
                        start = index + 1
                    }
                    index += 1
                }
                let remainder = available - start
                if start > 0, remainder > 0 {
                    memmove(buffer.baseAddress!, buffer.baseAddress! + start, remainder)
                }
                return remainder
            }
        }
    }

    private func handleLine(_ line: UnsafeBufferPointer<UInt8>) {
        guard let first = line.first else { return }
        if first >= 48, first <= 57 {  // Trace lines start with a timestamp.
            if let write = FSUsageParser.parse(line) { onWrite?(write) }
            return
        }
        // Anything else is the helper or fs_usage explaining a problem.
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { self.onDiagnostic?(text) }
    }
}
