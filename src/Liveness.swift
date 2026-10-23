import Darwin
import Foundation

/// Is this pid still a live, running process?
///
/// `kill(pid, 0)` is not enough. A zombie answers signal 0 with success, so a
/// session that was killed and left unreaped would keep its row in the panel
/// forever. sysctl gives the process state without forking, which matters because
/// this runs once a second for every local session.
func processIsAlive(_ pid: Int32, started: String? = nil) -> Bool {
    guard pid > 0 else { return false }
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
    // A failed call or an empty result means no such process.
    guard result == 0, size > 0 else { return false }
    // SZOMB is 5. Spelled out because the constant is not exported to Swift.
    guard info.kp_proc.p_stat != 5 else { return false }
    guard let started, !started.isEmpty else { return true }
    let actual = Date(timeIntervalSince1970: Double(info.kp_proc.p_starttime.tv_sec))
    return normalizedProcessStart(started) == normalizedProcessStart(processStartFormatter.string(from: actual))
}

private let processStartFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return formatter
}()

private func normalizedProcessStart(_ start: String) -> String {
    start.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
