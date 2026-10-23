import CryptoKit
import Foundation

struct StreamFrame: Decodable {
    let type: String
    let host: String?
    let version: Int?
    let file: String?
    let offset: UInt64?
    let content: String?
    let time: Int?
    let alive: [String: Bool]?
    let error: String?
    let titles: [String: String]?

    enum CodingKeys: String, CodingKey {
        case type, host, file, offset, content, time, alive, error, titles
        case version = "protocol"
    }
}

enum StreamError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let reason): return reason
        }
    }
}

/// The cache length is the receive cursor. A crash cannot advance it past saved bytes.
final class RemoteCache {
    let directory: URL
    private let host: String
    private var greeted = false

    init(directory: URL, host: String) throws {
        guard !host.isEmpty, !host.contains("/"), host != ".", host != ".." else {
            throw StreamError.invalid("invalid stream host")
        }
        self.directory = directory
        self.host = host
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    func request() throws -> Data {
        var offsets: [String: [String: Any]] = [:]
        for name in EventReader.eventFileNames(in: directory) {
            let url = try fileURL(name)
            offsets[name] = try cursor(url)
        }
        var request = try JSONSerialization.data(withJSONObject: ["protocol": 1, "offsets": offsets, "progress": true])
        request.append(0x0A)
        return request
    }

    private func cursor(_ url: URL) throws -> [String: Any] {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var size = try handle.seekToEnd()
        let start = size > 65_536 ? size - 65_536 : 0
        try handle.seek(toOffset: start)
        var tail = try handle.readToEnd() ?? Data()
        if size > 0, tail.last != 0x0A {
            // An interrupted cache write can leave a partial record. The source retains it.
            guard let newline = tail.lastIndex(of: 0x0A) else {
                guard start == 0 else { throw StreamError.invalid("cache record exceeds 64 KiB") }
                try handle.truncate(atOffset: 0)
                return ["offset": 0, "tail": SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()]
            }
            tail = Data(tail.prefix(through: newline))
            size = start + UInt64(tail.count)
            try handle.truncate(atOffset: size)
        }
        let digest = SHA256.hash(data: tail.suffix(4096)).map { String(format: "%02x", $0) }.joined()
        return ["offset": size, "tail": digest]
    }

    func accept(_ frame: StreamFrame) throws -> Bool {
        if frame.type == "error" {
            throw StreamError.invalid(frame.error ?? "remote stream failed")
        }
        if frame.type == "hello" {
            guard !greeted, frame.host == host, frame.version == 1 else {
                throw StreamError.invalid("remote host or protocol mismatch")
            }
            greeted = true
            return false
        }
        guard greeted else { throw StreamError.invalid("stream did not identify its host") }
        switch frame.type {
        case "chunk": return try append(frame)
        case "progress":
            guard frame.time != nil else { throw StreamError.invalid("incomplete remote progress") }
            return false
        case "status":
            guard frame.time != nil, frame.alive != nil else {
                throw StreamError.invalid("incomplete remote status")
            }
            if let titles = frame.titles {
                let bytes = try JSONEncoder().encode(titles)
                try bytes.write(to: directory.appendingPathComponent("titles.json"), options: .atomic)
            }
            return false
        default: throw StreamError.invalid("unknown stream frame: \(frame.type)")
        }
    }

    private func fileURL(_ name: String) throws -> URL {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: host) + "-[0-9]{4}-[0-9]{2}-[0-9]{2}\\.jsonl$"
        guard name.range(of: pattern, options: .regularExpression) != nil else {
            throw StreamError.invalid("invalid stream filename: \(name)")
        }
        let url = directory.appendingPathComponent(name)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let attributes, attributes[.type] as? FileAttributeType != .typeRegular {
            throw StreamError.invalid("cache path is not a regular file: \(name)")
        }
        return url
    }

    private func append(_ frame: StreamFrame) throws -> Bool {
        guard let name = frame.file, let offset = frame.offset, let encoded = frame.content,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.last == 0x0A else {
            throw StreamError.invalid("incomplete stream chunk")
        }
        let url = try fileURL(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw StreamError.invalid("cannot create cache file: \(name)")
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        guard try handle.seekToEnd() == offset else {
            throw StreamError.invalid("stream cursor mismatch: \(name)")
        }
        do {
            try handle.write(contentsOf: bytes)
        } catch {
            try handle.truncate(atOffset: offset)
            throw error
        }
        return true
    }
}
