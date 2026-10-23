import Darwin
import Foundation

/// Metadata caches must detect replacements and rewrites even when mtime is restored.
struct FileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let mode: mode_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    var isRegular: Bool { mode & S_IFMT == S_IFREG }
    var isPrecise: Bool { modifiedNanoseconds != 0 && changedNanoseconds != 0 }

    init?(_ url: URL) {
        var attributes = stat()
        guard stat(url.path, &attributes) == 0 else { return nil }
        device = attributes.st_dev
        inode = attributes.st_ino
        size = attributes.st_size
        mode = attributes.st_mode
        modifiedSeconds = attributes.st_mtimespec.tv_sec
        modifiedNanoseconds = attributes.st_mtimespec.tv_nsec
        changedSeconds = attributes.st_ctimespec.tv_sec
        changedNanoseconds = attributes.st_ctimespec.tv_nsec
    }
}
