import Foundation
import Darwin

/// Records our adapter ownership before calibration can disconnect wall power.
/// Callers must protect the parent directory and serialize access with the
/// helper's exclusive lock.
public struct AdapterRecoveryStore {
    private let path: String
    public init(path: String) { self.path = path }

    public func read() throws -> Bool {
        // Nonblocking avoids waiting on a FIFO before its type can be rejected.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return false }
            throw failure("open", code: code)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw failure("inspect") }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0 else {
            throw SaverError("Adapter recovery record must be a regular file owned by the current effective user with no group or other write access.")
        }
        guard metadata.st_size > 0, metadata.st_size < 64 else {
            throw SaverError("Adapter recovery record is empty or invalid.")
        }
        var bytes = [UInt8](repeating: 0, count: 64)
        var length = 0
        while length < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: length), buffer.count - length)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("read")
            }
            if count == 0 { break }
            length += count
        }
        guard length < bytes.count,
              let value = try? JSONDecoder().decode(Bool.self, from: Data(bytes.prefix(length))) else {
            throw SaverError("Adapter recovery record is corrupt; adapter ownership cannot be verified.")
        }
        return value
    }

    public func write(_ owned: Bool) throws {
        // Refuse unsafe or corrupt existing records rather than clearing an
        // ownership state we cannot establish.
        _ = try read()
        let temporary = path + ".\(UUID().uuidString).tmp"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("create temporary") }
        defer { close(descriptor); unlink(temporary) }
        guard fchmod(descriptor, 0o600) == 0 else { throw failure("set permissions on") }
        let bytes = Array((owned ? "true\n" : "false\n").utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("write")
            }
            guard count > 0 else { throw SaverError("Cannot write adapter recovery record: no progress.") }
            written += count
        }
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw failure("synchronize")
        }
        // Commit only after synchronization. Any earlier failure leaves an
        // existing true record intact. Nothing after rename can throw.
        guard rename(temporary, path) == 0 else { throw failure("replace") }
    }

    private func failure(_ operation: String, code: Int32 = errno) -> SaverError {
        SaverError("Cannot \(operation) adapter recovery record: \(String(cString: strerror(code))).")
    }
}
