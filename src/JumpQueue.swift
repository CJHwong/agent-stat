import Foundation

struct JumpExecution {
    let summary: String
    let outcome: JumpOutcome
}

final class JumpQueue {
    private let queue = DispatchQueue(label: "agent-stat.navigation")
    private let lock = NSLock()
    private var generation = 0

    func submit(_ operation: @escaping () -> JumpExecution,
                completion: @escaping @MainActor (JumpExecution) -> Void) {
        lock.lock()
        generation += 1
        let ticket = generation
        lock.unlock()
        queue.async {
            guard self.isCurrent(ticket) else { return }
            let result = CommandRunner.withDeadline(operation)
            DispatchQueue.main.async {
                guard self.isCurrent(ticket) else { return }
                completion(result)
            }
        }
    }

    private func isCurrent(_ ticket: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ticket == generation
    }
}
