import CryptoKit
import Foundation

private let transportHost = "peer"
private let transportFile = "peer-2026-10-23.jsonl"

private struct TransportRequest: Decodable {
    struct Cursor: Decodable {
        let offset: UInt64
        let tail: String
    }

    let version: Int
    let offsets: [String: Cursor]

    enum CodingKeys: String, CodingKey {
        case version = "protocol"
        case offsets
    }
}

private func transportFrame(_ fields: [String: Any]) throws -> StreamFrame {
    let encoded = try JSONSerialization.data(withJSONObject: fields)
    return try JSONDecoder().decode(StreamFrame.self, from: encoded)
}

private func transportHello(host: String = transportHost, version: Int = 1) throws -> StreamFrame {
    try transportFrame(["type": "hello", "host": host, "protocol": version])
}

private func transportChunk(_ content: Data, file: String = transportFile,
                            offset: UInt64 = 0) throws -> StreamFrame {
    try transportFrame(["type": "chunk", "file": file, "offset": offset,
                        "content": content.base64EncodedString()])
}

private func transportRejects(_ label: String, _ operation: () throws -> Void) {
    do {
        try operation()
        check(false, label)
    } catch {
        check(true, label)
    }
}

private func transportRejectPath(_ name: String, cache: RemoteCache, line: Data) {
    transportRejects("unowned path fails: \(name)") {
        _ = try cache.accept(transportChunk(line, file: name))
    }
}

private func transportCase(_ label: String, _ body: (URL) throws -> Void) {
    withTempDir { directory in
        do {
            try body(directory)
        } catch {
            check(false, "\(label): \(error)")
        }
    }
}

private func transportRequest(_ cache: RemoteCache) throws -> TransportRequest {
    let encoded = try cache.request()
    checkEqual(encoded.last, UInt8(10), "resume request ends with a newline")
    return try JSONDecoder().decode(TransportRequest.self, from: encoded)
}

func testTransportHandshake() {
    print("transport: handshake")
    transportCase("handshake") { directory in
        let cache = try RemoteCache(directory: directory, host: transportHost)
        let line = Data("{\"session\":\"first\"}\n".utf8)
        transportRejects("chunk before hello fails") {
            _ = try cache.accept(transportChunk(line))
        }
        transportRejects("wrong hello host fails") {
            _ = try cache.accept(transportHello(host: "another-peer"))
        }
        transportRejects("wrong protocol fails") {
            _ = try cache.accept(transportHello(version: 2))
        }
        transportRejects("failed hello does not permit chunks") {
            _ = try cache.accept(transportChunk(line))
        }
        checkEqual(try cache.accept(transportHello()), false, "hello appends no records")
        let progress = try transportFrame(["type": "progress", "time": 100])
        checkEqual(try cache.accept(progress), false, "history progress does not append records")
        let fields = try JSONSerialization.jsonObject(with: cache.request()) as? [String: Any]
        checkEqual(fields?["progress"] as? Bool, true, "the receiver requests optional history progress")
        transportRejects("progress requires a timestamp") {
            _ = try cache.accept(transportFrame(["type": "progress"]))
        }
        let status = try transportFrame(["type": "status", "time": 100,
                                         "alive": ["first": true]])
        checkEqual(try cache.accept(status), false, "status appends no records")
        let request = try transportRequest(cache)
        let namedStatus = try transportFrame(["type": "status", "time": 100,
            "alive": ["first": true], "titles": ["first": "Quiet name"]])
        _ = try cache.accept(namedStatus)
        checkEqual(CodexTitles.cached(in: directory)["first"], "Quiet name", "status caches remote names")
        _ = try cache.accept(status)
        checkEqual(CodexTitles.cached(in: directory)["first"], "Quiet name", "older helper preserves cached names")
        checkEqual(request.version, 1, "request uses protocol one")
        check(request.offsets.isEmpty, "handshake creates no event files")
        checkEqual(try cache.accept(transportChunk(line)), true, "verified host can append")
    }
}

func testTransportResume() {
    print("transport: bytes, resume, and disk persistence")
    transportCase("resume") { directory in
        let cache = try RemoteCache(directory: directory, host: transportHost)
        _ = try cache.accept(transportHello())
        let longMessage = String(repeating: "臺", count: 1600)
        let first = Data(("{\"ts\":100,\"event\":\"Stop\",\"session\":\"first\",\"message\":\"\(longMessage)\"}\n"
                          + "{\"ts\":101,\"event\":\"Stop\",\"session\":\"second\",\"message\":\"第二行\"}\n").utf8)
        checkEqual(try cache.accept(transportChunk(first)), true, "UTF-8 records append together")
        let path = cache.directory.appendingPathComponent(transportFile)
        checkEqual(try Data(contentsOf: path), first, "cache preserves the exact UTF-8 bytes")
        let request = try transportRequest(cache)
        checkEqual(request.offsets[transportFile]?.offset, UInt64(first.count),
                   "resume cursor counts bytes")
        let tail = SHA256.hash(data: first.suffix(4096)).map { String(format: "%02x", $0) }.joined()
        checkEqual(request.offsets[transportFile]?.tail, tail,
                   "resume hash covers the final 4096 bytes")

        let reconnected = try RemoteCache(directory: directory, host: transportHost)
        let resumed = try transportRequest(reconnected)
        checkEqual(resumed.offsets[transportFile]?.offset, UInt64(first.count),
                   "new cache reads the stored cursor")
        checkEqual(resumed.offsets[transportFile]?.tail, tail, "new cache reads the stored hash")
        let second = Data("{\"ts\":102,\"event\":\"Stop\",\"session\":\"third\",\"message\":\"reconnected\"}\n".utf8)
        transportRejects("reconnect requires a new hello") {
            _ = try reconnected.accept(transportChunk(second, offset: UInt64(first.count)))
        }
        _ = try reconnected.accept(transportHello())
        checkEqual(try reconnected.accept(transportChunk(second, offset: UInt64(first.count))), true,
                   "reconnect appends only unseen bytes")
        checkEqual(try Data(contentsOf: path), first + second, "reconnect preserves prior records once")
        let reader = EventReader()
        checkEqual(reader.poll(directory: reconnected.directory).count, 3,
                   "normal event reader reads every cached record once")
        checkEqual(reader.poll(directory: reconnected.directory).count, 0,
                   "normal event reader does not replay cached records")
    }
}

func testTransportInvalidChunks() {
    print("transport: reject invalid chunks")
    transportCase("invalid chunks") { directory in
        let cache = try RemoteCache(directory: directory, host: transportHost)
        _ = try cache.accept(transportHello())
        let first = Data("{\"session\":\"first\"}\n".utf8)
        _ = try cache.accept(transportChunk(first))
        let next = Data("{\"session\":\"next\"}\n".utf8)
        transportRejects("duplicate offset fails") {
            _ = try cache.accept(transportChunk(first))
        }
        transportRejects("gap in offsets fails") {
            _ = try cache.accept(transportChunk(next, offset: UInt64(first.count + 1)))
        }
        transportRejects("partial final record fails") {
            _ = try cache.accept(transportChunk(Data("{\"session\":\"partial\"}".utf8),
                                              offset: UInt64(first.count)))
        }
        transportRejects("invalid base64 fails") {
            let invalid = try transportFrame(["type": "chunk", "file": transportFile,
                                               "offset": first.count, "content": "***"])
            _ = try cache.accept(invalid)
        }
        let path = cache.directory.appendingPathComponent(transportFile)
        checkEqual(try Data(contentsOf: path), first, "rejected chunks leave cached bytes intact")
        checkEqual(try cache.accept(transportChunk(next, offset: UInt64(first.count))), true,
                   "rejected chunks do not advance the cursor")
        checkEqual(try Data(contentsOf: path), first + next, "valid append still works after rejection")
    }
}

func testTransportInterruptedCache() {
    print("transport: recover interrupted cache writes")
    let first = Data("{\"ts\":100,\"event\":\"Stop\",\"session\":\"first\",\"message\":\"臺灣\"}\n".utf8)
    let second = Data("{\"ts\":101,\"event\":\"Stop\",\"session\":\"second\",\"message\":\"復原\"}\n".utf8)
    transportCase("trailing partial record") { directory in
        let cache = try RemoteCache(directory: directory, host: transportHost)
        let path = cache.directory.appendingPathComponent(transportFile)
        try (first + second.prefix(second.count / 2)).write(to: path)
        let request = try transportRequest(cache)
        let digest = SHA256.hash(data: first).map { String(format: "%02x", $0) }.joined()
        checkEqual(request.offsets[transportFile]?.offset, UInt64(first.count),
                   "interrupted cache resumes after the complete UTF-8 record")
        checkEqual(request.offsets[transportFile]?.tail, digest,
                   "interrupted cache hashes only complete bytes")
        checkEqual(try Data(contentsOf: path), first, "request removes only the incomplete suffix")
        _ = try cache.accept(transportHello())
        checkEqual(try cache.accept(transportChunk(second, offset: UInt64(first.count))), true,
                   "source can resend the interrupted record")
        checkEqual(try Data(contentsOf: path), first + second,
                   "resend preserves the complete record without a duplicate")
        checkEqual(EventReader().poll(directory: cache.directory).count, 2,
                   "recovered cache contains exactly two records")
    }
    transportCase("entirely partial record") { directory in
        let cache = try RemoteCache(directory: directory, host: transportHost)
        let path = cache.directory.appendingPathComponent(transportFile)
        try first.prefix(first.count / 2).write(to: path)
        let request = try transportRequest(cache)
        let digest = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        checkEqual(request.offsets[transportFile]?.offset, UInt64(0),
                   "entirely partial cache resumes from zero")
        checkEqual(request.offsets[transportFile]?.tail, digest,
                   "empty recovered cache uses the empty hash")
        checkEqual(try Data(contentsOf: path), Data(), "entirely partial cache truncates to zero")
        _ = try cache.accept(transportHello())
        checkEqual(try cache.accept(transportChunk(first)), true, "source can resend from byte zero")
        checkEqual(try Data(contentsOf: path), first, "zero-byte recovery saves the complete source record")
        checkEqual(EventReader().poll(directory: cache.directory).count, 1,
                   "zero-byte recovery contains exactly one record")
    }
}

func testTransportPaths() {
    print("transport: path ownership")
    transportCase("paths") { directory in
        let cache = try RemoteCache(directory: directory, host: transportHost)
        _ = try cache.accept(transportHello())
        let line = Data("{\"session\":\"first\"}\n".utf8)
        let invalidNames = ["../peer-2026-10-23.jsonl", "/tmp/peer-2026-10-23.jsonl",
                            "nested/peer-2026-10-23.jsonl", "workstation-2026-10-23.jsonl",
                            "peer-extra-2026-10-23.jsonl", "peer.jsonl",
                            "peer-2026-10-23.sync-conflict-1.jsonl"]
        for name in invalidNames {
            transportRejectPath(name, cache: cache, line: line)
        }
        let target = directory.appendingPathComponent("outside.jsonl")
        let original = Data("original\n".utf8)
        try original.write(to: target)
        let linked = cache.directory.appendingPathComponent(transportFile)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        transportRejects("symlink destination fails") {
            _ = try cache.accept(transportChunk(line, offset: UInt64(original.count)))
        }
        checkEqual(try Data(contentsOf: target), original, "symlink target stays intact")
    }
}

func testRemoteSessionLiveness() {
    print("transport: remote process status")
    let store = SessionStore(localHost: HOST)
    let now = 800_000
    let event = decode(#"{"ts":\#(now),"event":"Stop","session":"shared","agent_pid":42,"message":"done"}"#)
    let remoteKey = SessionKey(host: transportHost, id: "shared")
    let localKey = SessionKey(host: HOST, id: "shared")
    let otherKey = SessionKey(host: "other-peer", id: "shared")
    store.apply(event, host: transportHost)
    store.apply(event, host: HOST)
    store.apply(event, host: "other-peer")
    store.reapRemote(host: transportHost, alive: ["shared": false, "unknown": false], now: now + 1)
    guard let dead = store.sessions[remoteKey] else {
        check(false, "remote session remains in store")
        return
    }
    checkEqual(dead.alive, false, "remote process can report dead")
    checkEqual(dead.goneSince, now + 1, "fresh remote death starts the grace period")
    check(!store.needsAttention(dead), "dead remote session does not ask for attention")
    check(store.visible(now: now + 1).contains { $0.key == remoteKey },
          "fresh remote death remains visible during grace")
    check(!store.visible(now: now + SessionStore.crashedGraceSeconds + 2).contains { $0.key == remoteKey },
          "dead remote session disappears after grace")
    check(store.sessions[localKey]?.alive == nil, "remote status cannot change local liveness")
    check(store.sessions[otherKey]?.alive == nil, "remote status cannot change another host")
    checkEqual(store.sessions.count, 3, "status cannot invent a session")
    checkEqual(dead.state, .idle, "status does not create an end event")
    checkEqual(dead.lastTs, now, "status does not move the event timestamp")
    checkEqual(dead.lastMessage, "done", "status does not replace the last message")
    store.reapRemote(host: transportHost, alive: ["shared": true], now: now + 70)
    checkEqual(store.sessions[remoteKey]?.alive, true, "remote process can revive")
    check(store.sessions[remoteKey]?.goneSince == nil, "revival clears the death timestamp")
    check(store.visible(now: now + 70).contains { $0.key == remoteKey }, "revival restores the row")
    checkEqual(store.attentionCount(now: now + 70), 3, "revival restores remote attention")
    store.reapRemote(host: HOST, alive: ["shared": false], now: now + 71)
    check(store.sessions[localKey]?.alive == nil, "remote API cannot reap the local host")

    let stale = SessionStore(localHost: HOST)
    stale.apply(event, host: transportHost)
    stale.reapRemote(host: transportHost, alive: ["shared": false], now: now + 100)
    checkEqual(stale.sessions[remoteKey]?.goneSince, now, "old remote events use their original timestamp")
    check(stale.visible(now: now + 100).isEmpty, "old remote death receives no new grace period")
}

func testRemoteTransport() {
    testTransportHandshake()
    testTransportResume()
    testTransportInvalidChunks()
    testTransportInterruptedCache()
    testTransportPaths()
    testRemoteSessionLiveness()
}
