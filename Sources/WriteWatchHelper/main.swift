// WriteWatchHelper: the only part of WriteWatch that runs as root.
//
// It connects back to the app over loopback, proves itself with a one-time token, and relays
// the output of a fixed fs_usage command. It accepts just two single-byte commands, starts no
// other program, and creates no files. It exits as soon as the app's connection closes.
//
// fs_usage's memory grows as it runs, so the helper restarts it past a limit. Usage:
//   WriteWatchHelper <port> <token> [memory limit in MB]

import Darwin

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4, let port = UInt16(arguments[1]), geteuid() == 0 else {
    exit(64)
}
let defaultMemoryLimitMB: UInt64 = 1536
let memoryLimitBytes = (arguments.count == 4 ? UInt64(arguments[3]) ?? defaultMemoryLimitMB : defaultMemoryLimitMB) * 1_000_000
let memoryCheckInterval = 5
let minimumSecondsBetweenRestarts = 60  // A limit below fs_usage's starting size can't cause a tight loop.

let socketFD = socket(AF_INET, SOCK_STREAM, 0)
guard socketFD >= 0 else { exit(71) }

var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = port.bigEndian
address.sin_addr.s_addr = inet_addr("127.0.0.1")
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard connected == 0 else { exit(69) }

func sendAll(_ pointer: UnsafeRawPointer, _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let sent = write(socketFD, pointer + offset, count - offset)
        if sent < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += sent
    }
    return true
}

func send(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    return bytes.withUnsafeBytes { sendAll($0.baseAddress!, $0.count) }
}

guard send(arguments[2] + "\n") else { exit(74) }

var childPID: pid_t = 0
var masterFD: Int32 = -1

func stopTrace() {
    if childPID > 0 {
        kill(childPID, SIGINT)  // Lets fs_usage release the kernel trace facility cleanly.
    }
    // Closed before waiting, so fs_usage can't stay blocked writing to a full terminal buffer.
    if masterFD >= 0 {
        close(masterFD)
        masterFD = -1
    }
    if childPID > 0 {
        var status: Int32 = 0
        waitpid(childPID, &status, 0)
        childPID = 0
    }
}

var traceStartTime = 0
var lastMemoryCheck = 0

func residentBytes(of pid: pid_t) -> UInt64? {
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
        }
    }
    return result == 0 ? info.ri_resident_size : nil
}

/// Returns false if the app can no longer be reached.
func restartTraceIfOverMemoryLimit() -> Bool {
    let now = time(nil)
    guard childPID > 0, now - lastMemoryCheck >= memoryCheckInterval else { return true }
    lastMemoryCheck = now
    guard now - traceStartTime >= minimumSecondsBetweenRestarts,
        let resident = residentBytes(of: childPID), resident > memoryLimitBytes
    else { return true }
    stopTrace()
    startTrace()
    // The leading newline ends any partial trace line the app is still holding.
    return send("\n#restarted\n")
}

func startTrace() {
    guard childPID == 0 else { return }

    // A pseudo-terminal makes fs_usage line-buffer its output, so events arrive immediately.
    var master: Int32 = -1
    var slave: Int32 = -1
    var size = winsize(ws_row: 50, ws_col: 512, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else {
        _ = send("#error Could not open a pseudo-terminal.\n")
        return
    }
    var attributes = termios()
    if tcgetattr(slave, &attributes) == 0 {
        cfmakeraw(&attributes)
        tcsetattr(slave, TCSANOW, &attributes)
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, master)
    posix_spawn_file_actions_addclose(&actions, socketFD)

    let path = "/usr/bin/fs_usage"
    let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup(path), strdup("-w"), strdup("-f"), strdup("diskio"), nil,
    ]
    let environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, path, &actions, nil, argv, environment)
    posix_spawn_file_actions_destroy(&actions)
    argv.forEach { free($0) }
    close(slave)

    guard spawned == 0 else {
        close(master)
        _ = send("#error Could not start fs_usage (\(spawned)).\n")
        return
    }
    childPID = pid
    masterFD = master
    traceStartTime = time(nil)
}

var buffer = [UInt8](repeating: 0, count: 65536)

while true {
    var descriptors = [pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)]
    if masterFD >= 0 {
        descriptors.append(pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0))
    }
    if poll(&descriptors, nfds_t(descriptors.count), Int32(memoryCheckInterval * 1000)) < 0 {
        if errno == EINTR { continue }
        break
    }

    if descriptors[0].revents != 0 {
        let count = read(socketFD, &buffer, 64)
        if count == 0 || (count < 0 && errno != EINTR) { break }
        if count > 0 {
            for byte in buffer[0..<count] {
                switch byte {
                case UInt8(ascii: "S"): startTrace()
                case UInt8(ascii: "X"): stopTrace()
                default: break
                }
            }
        }
    }

    if descriptors.count > 1, masterFD >= 0, descriptors[1].revents != 0 {
        let count = read(masterFD, &buffer, buffer.count)
        if count > 0 {
            let sent = buffer.withUnsafeBytes { sendAll($0.baseAddress!, count) }
            if !sent { break }
        } else if count == 0 || errno != EINTR {
            // The trace ended by itself, for example because another tool owns the facility.
            stopTrace()
            guard send("#stopped\n") else { break }
        }
    }

    if !restartTraceIfOverMemoryLimit() { break }
}

stopTrace()
close(socketFD)
exit(0)
