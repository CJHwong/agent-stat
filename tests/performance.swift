import Foundation

@main
struct PerformanceProbe {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let events = root.appendingPathComponent("events")
        let home = root.appendingPathComponent("home")
        measure("history_read", iterations: 3) { EventReader().poll(directory: events).count }
        let reader = EventReader()
        _ = reader.poll(directory: events)
        measure("unchanged_poll_100", iterations: 3) {
            (0..<100).reduce(0) { result, _ in result + reader.poll(directory: events).count }
        }
        let names = CodexTitles()
        measure("unchanged_names_30", iterations: 3) {
            (0..<30).reduce(0) { result, _ in result + names.read(home: home).count }
        }
    }

    private static func measure(_ label: String, iterations: Int, body: () -> Int) {
        var elapsed: [Double] = []
        var checksum = 0
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            checksum += body()
            elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let median = elapsed.sorted()[elapsed.count / 2]
        print("\(label): \(String(format: "%.3f", median)) ms, checksum=\(checksum)")
    }
}
