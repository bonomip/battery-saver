import Foundation
import Darwin

/// Keeps one process in control until this object is released. The lock file
/// stays in place so another opener cannot acquire a different inode.
public final class ExclusiveFileLock {
    private let descriptor: Int32

    public init(path: String) throws {
        let opened = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard opened >= 0 else {
            throw SaverError("Cannot open helper control lock: \(String(cString: strerror(errno))).")
        }
        do {
            var metadata = stat()
            guard fstat(opened, &metadata) == 0 else {
                throw SaverError("Cannot inspect helper control lock: \(String(cString: strerror(errno))).")
            }
            guard metadata.st_mode & S_IFMT == S_IFREG else {
                throw SaverError("Helper control lock must be a regular file.")
            }
            guard metadata.st_uid == geteuid() else {
                throw SaverError("Helper control lock must belong to the current effective user.")
            }
            guard metadata.st_mode & 0o022 == 0 else {
                throw SaverError("Helper control lock must not grant group or other write access.")
            }
            guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw SaverError("Another Battery Saver helper or restoration is already running.")
                }
                throw SaverError("Cannot acquire helper control lock: \(String(cString: strerror(code))).")
            }
            descriptor = opened
        } catch {
            close(opened)
            throw error
        }
    }

    deinit { close(descriptor) }
}
