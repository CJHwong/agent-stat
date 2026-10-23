import Darwin
import Foundation

@main
struct StreamLifecycleProbe {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5, let stopAfter = Double(arguments[2]) else { exit(2) }
        let stream = RemoteStream(host: "lifecycle", argv: Array(arguments.dropFirst(3)),
                                  directory: URL(fileURLWithPath: arguments[1])) { _, state, _ in
            print(state)
            fflush(stdout)
        }
        stream.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) { stream.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter + 2) { exit(0) }
        dispatchMain()
    }
}
