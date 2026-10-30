import XCTest
import Darwin
@testable import BatteryCore

final class ExclusiveFileLockTests: XCTestCase {
    private func withDirectory(_ body: (String) throws -> Void) throws {
        let path = "/private/tmp/battery-saver-lock-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    func testExclusiveOwnershipAndReacquisitionAfterRelease() throws {
        try withDirectory { directory in
            let path = directory + "/control.lock"
            var owner: ExclusiveFileLock? = try ExclusiveFileLock(path: path)
            try withExtendedLifetime(owner) {
                XCTAssertThrowsError(try ExclusiveFileLock(path: path)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("already"))
                }
            }
            owner = nil
            XCTAssertNoThrow(try ExclusiveFileLock(path: path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            var metadata = stat()
            XCTAssertEqual(lstat(path, &metadata), 0)
            XCTAssertEqual(metadata.st_uid, geteuid())
            XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        }
    }

    func testSymlinkIsRejectedWithoutFollowingItsTarget() throws {
        try withDirectory { directory in
            let path = directory + "/control.lock"
            let target = directory + "/untouched"
            XCTAssertEqual(symlink(target, path), 0)
            XCTAssertThrowsError(try ExclusiveFileLock(path: path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        }
    }

    func testDirectoryIsRejected() throws {
        try withDirectory { directory in
            XCTAssertThrowsError(try ExclusiveFileLock(path: directory))
        }
    }

    func testWritableByOthersIsRejectedAndDoesNotKeepALock() throws {
        try withDirectory { directory in
            let path = directory + "/control.lock"
            try Data().write(to: URL(fileURLWithPath: path))
            XCTAssertEqual(chmod(path, 0o622), 0)
            XCTAssertThrowsError(try ExclusiveFileLock(path: path)) { error in
                XCTAssertTrue(error.localizedDescription.contains("write"))
            }
            XCTAssertEqual(chmod(path, 0o600), 0)
            XCTAssertNoThrow(try ExclusiveFileLock(path: path))
        }
    }
}
