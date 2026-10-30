import XCTest
import Darwin
@testable import BatteryCore

final class AdapterRecoveryStoreTests: XCTestCase {
    private func withDirectory(_ body: (String) throws -> Void) throws {
        let path = "/private/tmp/battery-saver-recovery-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    func testMissingMarkerMeansNoRecordedOwnership() throws {
        try withDirectory { directory in
            XCTAssertFalse(try AdapterRecoveryStore(path: directory + "/adapter.json").read())
        }
    }

    func testRoundTripUsesPrivateCurrentUserFile() throws {
        try withDirectory { directory in
            let path = directory + "/adapter.json"
            let store = AdapterRecoveryStore(path: path)
            try store.write(true)
            XCTAssertTrue(try AdapterRecoveryStore(path: path).read())
            try store.write(false)
            XCTAssertFalse(try store.read())
            var metadata = stat()
            XCTAssertEqual(lstat(path, &metadata), 0)
            XCTAssertEqual(metadata.st_uid, geteuid())
            XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), ["adapter.json"])
        }
    }

    func testCorruptMarkerIsRejectedWithoutOverwritingIt() throws {
        try withDirectory { directory in
            let path = directory + "/adapter.json"
            let original = Data("not a boolean".utf8)
            try original.write(to: URL(fileURLWithPath: path))
            XCTAssertEqual(chmod(path, 0o600), 0)
            let store = AdapterRecoveryStore(path: path)
            XCTAssertThrowsError(try store.read())
            XCTAssertThrowsError(try store.write(false))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        }
    }

    func testSymlinkIsRejectedWithoutCreatingItsTarget() throws {
        try withDirectory { directory in
            let path = directory + "/adapter.json"
            let target = directory + "/untouched"
            XCTAssertEqual(symlink(target, path), 0)
            let store = AdapterRecoveryStore(path: path)
            XCTAssertThrowsError(try store.read())
            XCTAssertThrowsError(try store.write(true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        }
    }

    func testNonregularMarkerIsRejected() throws {
        try withDirectory { directory in
            let store = AdapterRecoveryStore(path: directory)
            XCTAssertThrowsError(try store.read())
            XCTAssertThrowsError(try store.write(true))
        }
    }

    func testUnsafePermissionsDoNotClearRecordedOwnership() throws {
        try withDirectory { directory in
            let path = directory + "/adapter.json"
            let store = AdapterRecoveryStore(path: path)
            try store.write(true)
            XCTAssertEqual(chmod(path, 0o622), 0)
            XCTAssertThrowsError(try store.read())
            XCTAssertThrowsError(try store.write(false))
            XCTAssertEqual(chmod(path, 0o600), 0)
            XCTAssertTrue(try store.read())
        }
    }
}
