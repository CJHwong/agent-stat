import Foundation

/// A stable record boundary survives a replay and distinguishes equal timestamps.
struct EventPosition: Codable, Comparable {
    let file: String
    let offset: UInt64

    static func < (left: EventPosition, right: EventPosition) -> Bool {
        left.file == right.file ? left.offset < right.offset : left.file < right.file
    }
}

/// Tails the events directory.
///
/// The watcher wakes the reader when hooks or remote streams append records.
/// A timer also polls as a fallback. File replacement remains supported for older
/// deployments that use a sync client.
///
/// Per file it remembers (inode, size, lines already applied, and the byte offset of
/// the last complete line). A sync client replacing the file changes the inode, which
/// forces a re-read, and the line count keeps the re-read from replaying events that
/// were already folded in. A file that only grew is read from the offset, so the work
/// is the appended bytes rather than the whole day file.
final class EventReader {
    struct FileState {
        var inode: UInt64
        var size: Int64
        var lines: Int
        var dirty: Bool
        /// Just past the last newline consumed, so the next read starts at a line.
        var offset: UInt64
    }

    private var files: [String: FileState] = [:]
    private(set) var undecodableLines = 0

    /// A record plus the machine it came from, taken from the file name.
    struct Applied {
        let record: Record
        let host: String
        let position: EventPosition
    }

    /// The events file names in a directory.
    ///
    /// readdir rather than FileManager.contentsOfDirectory: Foundation's version builds
    /// a URL and reads resource properties for every entry, which costs milliseconds
    /// and runs on every poll.
    static func eventFileNames(in directory: URL) -> [String] {
        guard let handle = opendir(directory.path) else { return [] }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard name.hasSuffix(".jsonl"), !name.contains(".sync-conflict") else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    /// Read whatever is new. Returns records in file order.
    func poll(directory: URL) -> [Applied] {
        let names = Self.eventFileNames(in: directory)
        guard !names.isEmpty || FileManager.default.fileExists(atPath: directory.path) else {
            files.removeAll()
            return []
        }

        var applied: [Applied] = []
        for name in names {
            let path = directory.appendingPathComponent(name).path
            applied.append(contentsOf: read(path: path, name: name))
        }

        // Forget files that vanished, so the map cannot grow forever.
        let known = Set(names)
        for name in files.keys where !known.contains(name) {
            files.removeValue(forKey: name)
        }
        return applied
    }

    /// The complete lines of a file, and whether the last one was left behind.
    ///
    /// A file that does not end in a newline has a line being written right now,
    /// most likely caught mid-sync. Leave it for the next poll rather than guess at
    /// malformed JSON.
    private func completeLines(of content: String) -> (lines: [String], dirty: Bool) {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard content.hasSuffix("\n") else {
            guard !lines.isEmpty else { return (lines, false) }
            lines.removeLast()
            return (lines, true)
        }
        if lines.last == "" { lines.removeLast() }
        return (lines, false)
    }

    private func read(path: String, name: String) -> [Applied] {
        // One stat, not attributesOfItem: Foundation's version also fetches extended
        // attributes, which costs two more syscalls per file per poll.
        var info = stat()
        guard stat(path, &info) == 0 else { return [] }
        let inode = UInt64(info.st_ino)
        let size = Int64(info.st_size)
        let previous = files[name]

        // A replacement that is smaller than what we saw is a different file, so
        // start counting lines from zero again.
        if let previous, previous.inode != inode, size < previous.size {
            files.removeValue(forKey: name)
        }
        let state = files[name]
        if let state, !state.dirty, state.inode == inode, state.size == size {
            return []
        }
        // A file that only grew is read from the last complete line. A new inode or a
        // shorter file is read whole, and the line count keeps the re-read from
        // replaying events already folded in.
        if let state, state.inode == inode, size >= state.size {
            return readTail(path: path, name: name, inode: inode, size: size, state: state)
        }
        return readWhole(path: path, name: name, inode: inode, size: size,
                         alreadyApplied: state?.lines ?? 0)
    }

    /// Read only what was appended, starting at the last complete line.
    ///
    /// A half written line stays past the offset, so the next poll sees it again
    /// together with the rest of the record.
    private func readTail(path: String, name: String, inode: UInt64, size: Int64,
                          state: FileState) -> [Applied] {
        let remaining = size - Int64(state.offset)
        guard remaining > 0, let handle = FileHandle(forReadingAtPath: path) else {
            files[name]?.size = size
            return []
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
        } catch {
            return []
        }
        guard let data = try? handle.read(upToCount: Int(remaining)),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        let (lines, dirty) = completeLines(of: content)
        files[name] = FileState(inode: inode, size: size,
                                lines: state.lines + lines.count,
                                dirty: dirty,
                                offset: state.offset + UInt64(completeBytes(of: data)))
        return decode(lines, name: name, offset: state.offset)
    }

    /// Read the whole file, skipping the lines already applied.
    private func readWhole(path: String, name: String, inode: UInt64, size: Int64,
                           alreadyApplied: Int) -> [Applied] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        let (lines, dirty) = completeLines(of: content)
        let start = alreadyApplied <= lines.count ? alreadyApplied : 0
        files[name] = FileState(inode: inode, size: size, lines: lines.count,
                                dirty: dirty, offset: UInt64(completeBytes(of: data)))
        let offset = lines.prefix(start).reduce(UInt64(0)) { $0 + UInt64($1.utf8.count + 1) }
        return decode(Array(lines[start...]), name: name, offset: offset)
    }

    private func decode(_ lines: [String], name: String, offset: UInt64) -> [Applied] {
        let decoder = JSONDecoder()
        let host = Self.host(fromFileName: name)
        var results: [Applied] = []
        var boundary = offset
        for line in lines {
            boundary += UInt64(line.utf8.count + 1)
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            do {
                results.append(Applied(record: try decoder.decode(Record.self, from: data),
                                       host: host,
                                       position: EventPosition(file: name, offset: boundary)))
            } catch {
                undecodableLines += 1
            }
        }
        return results
    }

    /// Bytes in the complete lines of a chunk: everything up to the last newline.
    private func completeBytes(of data: Data) -> Int {
        guard let last = data.lastIndex(of: 0x0A) else { return 0 }
        return data.distance(from: data.startIndex, to: last) + 1
    }

    /// "workstation-2026-10-16.jsonl" -> "workstation".
    /// The host name may itself contain dashes, so only the trailing date is cut.
    static func host(fromFileName name: String) -> String {
        var stem = name
        if stem.hasSuffix(".jsonl") { stem.removeLast(".jsonl".count) }
        let parts = stem.split(separator: "-")
        guard parts.count > 3 else { return stem }
        return parts.dropLast(3).joined(separator: "-")
    }
}
