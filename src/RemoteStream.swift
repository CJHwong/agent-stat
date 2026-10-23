import Darwin
import Foundation

/// Each connection has one serial queue. The app receives updates on the main queue.
final class RemoteStream {
    typealias Update = (String, String, [String: Bool]?) -> Void

    private let host: String
    private let argv: [String]
    private let directory: URL
    private let update: Update
    private let queue: DispatchQueue
    private var process: Process?
    private var output: Pipe?
    private var input: Pipe?
    private var errors: Pipe?
    private var diagnostic = Data()
    private var cache: RemoteCache?
    private var pending = Data()
    private var watchdog: DispatchSourceTimer?
    private var lastFrame = Date()
    private var retrySeconds: Double = 1
    private var stopped = false
    private var generation = 0
    private var caughtUp = false

    init(host: String, argv: [String], directory: URL, update: @escaping Update) {
        self.host = host
        self.argv = argv
        self.directory = directory
        self.update = update
        queue = DispatchQueue(label: "agent-stat.stream.\(host)")
    }

    func start() {
        queue.async { self.connect() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.disconnect()
        }
    }

    private func publish(_ state: String, alive: [String: Bool]? = nil) {
        DispatchQueue.main.async { self.update(self.host, state, alive) }
    }

    private func connect() {
        guard !stopped, !argv.isEmpty else { return }
        generation += 1
        let attempt = generation
        caughtUp = false
        publish("catching up")
        do {
            let cache = try RemoteCache(directory: directory, host: host)
            self.cache = cache
            let request = try cache.request()
            let process = Process()
            let output = Pipe()
            let input = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
            process.standardOutput = output
            process.standardInput = input
            process.standardError = errors
            process.terminationHandler = { [weak self] _ in
                self?.queue.async { self?.failed("connection closed", attempt: attempt) }
            }
            self.process = process
            self.output = output
            self.input = input
            self.errors = errors
            try process.run()
            errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                self?.queue.async { self?.receiveDiagnostic(bytes, attempt: attempt) }
            }
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                self?.queue.async { self?.received(bytes, attempt: attempt) }
            }
            lastFrame = Date()
            startWatchdog(attempt: attempt)
            try sendRequest(request, handle: input.fileHandleForWriting, attempt: attempt)
        } catch {
            failed(String(describing: error), attempt: attempt)
        }
    }

    private func sendRequest(_ request: Data, handle: FileHandle, attempt: Int) throws {
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // A helper may stall before reading stdin. Keep writes off the watchdog queue.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try handle.write(contentsOf: request)
                try handle.close()
            } catch {
                self?.queue.async { self?.failed(String(describing: error), attempt: attempt) }
            }
        }
    }

    private func receiveDiagnostic(_ bytes: Data, attempt: Int) {
        guard generation == attempt else { return }
        diagnostic.append(bytes.prefix(max(0, 8192 - diagnostic.count)))
    }

    private func startWatchdog(attempt: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastFrame) > 20 else { return }
            self.failed("remote stream timed out", attempt: attempt)
        }
        timer.resume()
        watchdog = timer
    }

    private func received(_ bytes: Data, attempt: Int) {
        guard generation == attempt, !stopped else { return }
        guard !bytes.isEmpty else { return }
        pending.append(bytes)
        do {
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                guard line.count <= 1_048_576 else {
                    throw StreamError.invalid("remote stream frame exceeds 1 MiB")
                }
                let frame = try JSONDecoder().decode(StreamFrame.self, from: line)
                guard let cache else { throw StreamError.invalid("stream has no cache") }
                let changed = try cache.accept(frame)
                pending.removeSubrange(...newline)
                lastFrame = Date()
                if changed { publish(caughtUp ? "connected" : "catching up") }
                if frame.type == "status" {
                    caughtUp = true
                    retrySeconds = 1
                    publish("connected", alive: frame.alive)
                }
            }
            guard pending.count <= 1_048_576 else {
                throw StreamError.invalid("remote stream frame exceeds 1 MiB")
            }
        } catch {
            failed(String(describing: error), attempt: attempt)
        }
    }

    private func disconnect() {
        generation += 1
        watchdog?.cancel()
        watchdog = nil
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        try? output?.fileHandleForReading.close()
        let writer = input?.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async { try? writer?.close() }
        try? errors?.fileHandleForReading.close()
        process = nil
        output = nil
        input = nil
        errors = nil
        pending.removeAll(keepingCapacity: true)
    }

    private func failed(_ reason: String, attempt: Int) {
        guard generation == attempt, !stopped else { return }
        let detail = String(data: diagnostic, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        disconnect()
        diagnostic.removeAll(keepingCapacity: true)
        publish("offline")
        DispatchQueue.main.async { Log.write("stream \(self.host): \(reason)\(detail.map { ": \($0)" } ?? "")") }
        let delay = retrySeconds
        retrySeconds = min(30, retrySeconds * 2)
        queue.asyncAfter(deadline: .now() + delay) { self.connect() }
    }
}
