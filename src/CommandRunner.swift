import Darwin
import Foundation

enum CommandRunner {
    private enum ReadState { case open, read, closed, failed }
    private static let deadlineKey = "agent-stat.command-deadline"

    static func withDeadline<Value>(timeout: TimeInterval = 10, _ operation: () -> Value) -> Value {
        let state = Thread.current.threadDictionary
        let previous = state[deadlineKey]
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        state[deadlineKey] = min(previous as? TimeInterval ?? deadline, deadline)
        defer {
            if let previous { state[deadlineKey] = previous } else { state.removeObject(forKey: deadlineKey) }
        }
        return operation()
    }
    struct Result {
        let status: Int32
        let output: String
        var timedOut = false
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> Result {
        let remaining = (Thread.current.threadDictionary[deadlineKey] as? TimeInterval)
            .map { $0 - ProcessInfo.processInfo.systemUptime } ?? timeout
        guard remaining > 0 else { return Result(status: -1, output: "command timed out", timedOut: true) }
        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else { return failure("cannot create command pipe") }
        let reader = descriptors[0]
        let writer = descriptors[1]
        defer { close(reader) }
        let spawned = spawn(path, arguments, reader: reader, writer: writer)
        close(writer)
        guard spawned.error == 0 else { return failure(String(cString: strerror(spawned.error))) }
        guard fcntl(reader, F_SETFL, O_NONBLOCK) != -1 else {
            stop(spawned.pid, reaped: false)
            return failure("cannot read command output")
        }
        return collect(reader, pid: spawned.pid, timeout: min(timeout, remaining))
    }

    private static func failure(_ message: String) -> Result {
        Result(status: -1, output: message)
    }

    private static func spawn(_ path: String, _ arguments: [String], reader: Int32,
                              writer: Int32) -> (pid: pid_t, error: Int32) {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return (0, ENOMEM) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return (0, ENOMEM) }
        defer { posix_spawnattr_destroy(&attributes) }
        let settings = [
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, reader),
            posix_spawn_file_actions_addclose(&actions, writer)
        ]
        guard let error = settings.first(where: { $0 != 0 }) else {
            return start(path, arguments, actions: &actions, attributes: &attributes)
        }
        return (0, error)
    }

    private static func start(_ path: String, _ arguments: [String],
                              actions: inout posix_spawn_file_actions_t?,
                              attributes: inout posix_spawnattr_t?) -> (pid: pid_t, error: Int32) {
        var argv = ([path] + arguments).map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            argv.forEach { free($0) }
            environment.forEach { free($0) }
        }
        var pid: pid_t = 0
        let error = posix_spawn(&pid, path, &actions, &attributes, &argv, &environment)
        return (pid, error)
    }

    private static func collect(_ reader: Int32, pid: pid_t, timeout: TimeInterval) -> Result {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard let events = events(reader, pid: pid) else {
            stop(pid, reaped: false)
            return failure("cannot watch command progress")
        }
        defer { close(events) }
        var output = Data()
        var status: Int32 = 0
        var reaped = false
        var closed = false
        while !reaped || !closed {
            let progress = closed ? ReadState.closed : drain(reader, into: &output)
            if case .failed = progress {
                stop(pid, reaped: reaped)
                return failure("cannot read command output")
            }
            if case .closed = progress { closed = true }
            if !reaped { reaped = waitpid(pid, &status, WNOHANG) == pid }
            if reaped && closed { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                stop(pid, reaped: reaped)
                return Result(status: -1, output: "command timed out", timedOut: true)
            }
            if case .read = progress { continue }
            guard waitForProgress(events, deadline: deadline) else {
                stop(pid, reaped: reaped)
                return failure("cannot wait for command progress")
            }
        }
        guard output.count <= 1_048_576 else { return failure("command output exceeded its limit") }
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        guard let text = String(data: output, encoding: .utf8) else { return failure("command output is not UTF-8") }
        return Result(status: exitCode, output: text)
    }

    private static func events(_ reader: Int32, pid: pid_t) -> Int32? {
        let queue = kqueue()
        guard queue >= 0 else { return nil }
        var changes = [
            kevent(ident: UInt(reader), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR),
                   fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                   fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        ]
        // A child can exit before registration. Its pipe still wakes the reader.
        if kevent(queue, &changes, Int32(changes.count), nil, 0, nil) >= 0 || errno == ESRCH { return queue }
        close(queue)
        return nil
    }

    private static func waitForProgress(_ events: Int32, deadline: TimeInterval) -> Bool {
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        var timeout = timespec(tv_sec: Int(remaining), tv_nsec: Int(remaining.truncatingRemainder(dividingBy: 1) * 1e9))
        var event = kevent()
        return kevent(events, nil, 0, &event, 1, &timeout) >= 0 || errno == EINTR
    }

    private static func drain(_ reader: Int32, into output: inout Data) -> ReadState {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(reader, &buffer, buffer.count)
        if count == 0 { return .closed }
        if count < 0 { return errno == EINTR ? .read : (errno == EAGAIN ? .open : .failed) }
        // Continue draining excess bytes so a noisy child cannot block its own exit.
        if output.count <= 1_048_576 { output.append(contentsOf: buffer.prefix(count)) }
        return .read
    }

    private static func stop(_ pid: pid_t, reaped: Bool) {
        // The spawned process owns a separate group, including descendants that hold the output pipe open.
        kill(-pid, SIGKILL)
        guard !reaped else { return }
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }
}
