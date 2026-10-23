import Darwin
import Foundation

/// Tells the panel the moment the events change, rather than waiting for the next poll.
///
/// The panel polls once a second for ages and for liveness, which is right for a clock
/// and wrong for a state change: when a session starts working or finishes, the row
/// should say so at once, and the hook has already written the record by then.
///
/// A directory source catches files appearing and going away. A directory source does not
/// report a write to a file inside it, so each file gets a source of its own.
final class EventWatcher {
    /// How many events files keep a descriptor. The directory gains one file per
    /// machine per day and never loses one, so watching all of them would grow
    /// without a bound. The newest files are the ones that change; the reader still
    /// polls every file once a second.
    private static let maxWatchedFiles = 8

    private let directory: URL
    private let onChange: () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryInode: UInt64?
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    /// The inode each source watches. A replacement names a new inode, and the old
    /// descriptor then reports nothing, so the two must be compared.
    private var fileInodes: [String: UInt64] = [:]

    init(directory: URL, onChange: @escaping () -> Void) {
        self.directory = directory
        self.onChange = onChange
        refresh()
    }

    deinit {
        directorySource?.cancel()
        for source in fileSources.values { source.cancel() }
    }

    /// Watch every events file, and forget the ones that went away.
    ///
    /// Called again after each poll, so a file that appears later, the next day file, is
    /// watched from then on.
    ///
    /// A file can also be replaced in place, which is what an atomic save and a sync
    /// client both do: the name stays, the inode does not. The descriptor then points at
    /// an unlinked file and reports nothing, so the name alone is not enough to decide
    /// that a file is already watched. The inode decides.
    func refresh() {
        refreshDirectory()
        let names = EventReader.eventFileNames(in: directory)
        // Newest first. A conflict copy is not watched at all: the reader ignores it,
        // so a write to one has nothing to report.
        let watched = names
            .map { (name: $0, modified: modifiedAt($0)) }
            .sorted { $0.modified > $1.modified }
            .prefix(Self.maxWatchedFiles)
            .map(\.name)
        for name in watched {
            let path = directory.appendingPathComponent(name).path
            if let known = fileInodes[name], let inode = inode(atPath: path),
               inode == known {
                continue
            }
            fileSources[name]?.cancel()
            fileSources[name] = nil
            fileInodes[name] = nil
            watchFile(name)
        }
        for name in Array(fileSources.keys) where !watched.contains(name) {
            fileSources[name]?.cancel()
            fileSources[name] = nil
            fileInodes[name] = nil
        }
    }

    /// The path can appear or change while the fallback polls, after its source ends.
    private func refreshDirectory() {
        let current = inode(atPath: directory.path)
        if current == directoryInode, directorySource != nil { return }
        directorySource?.cancel()
        directorySource = nil
        directoryInode = nil
        watchDirectory()
    }

    private func watchDirectory() {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        directoryInode = inode(ofDescriptor: descriptor)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
        source.setEventHandler { [weak self] in
            self?.refresh()
            self?.onChange()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
    }

    private func watchFile(_ name: String) {
        let path = directory.appendingPathComponent(name).path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.onChange() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileSources[name] = source
        fileInodes[name] = inode(ofDescriptor: descriptor)
    }

    /// When a file last changed, or a time far enough back to sort last.
    private func modifiedAt(_ name: String) -> Date {
        let path = directory.appendingPathComponent(name).path
        var info = stat()
        guard stat(path, &info) == 0 else { return .distantPast }
        let seconds = Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    /// The inode behind an open descriptor, which is the file it actually watches.
    private func inode(ofDescriptor descriptor: Int32) -> UInt64? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    /// The inode a path names right now, or nil when it is gone.
    private func inode(atPath path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }
}
