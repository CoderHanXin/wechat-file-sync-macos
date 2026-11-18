import Foundation
import Testing
@testable import SyncCore

final class FileSystemTests {
    @Test func testCheckedPathsRejectTraversalAndSymlinkParents() throws {
        let f = try Fixture()
        for relative in ["", "/absolute", "../outside", "sub/../outside", "./file", "sub//file", "bad\0file"] {
            #expect(throws: (any Error).self) { try checkedFile(f.managedRoot, relative: relative) }
        }
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.target("escape"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try checkedFile(f.managedRoot, relative: "escape/file.txt") }
        #expect(try checkedFile(f.managedRoot, relative: "普通文件.txt") == f.target("普通文件.txt"))
    }

    @Test func testDirectoriesCannotOverlap() throws {
        let f = try Fixture()
        #expect(throws: (any Error).self) { try initialState(source: f.source, managedRoot: f.source) }
        #expect(throws: (any Error).self) { try initialState(source: f.source, managedRoot: f.root) }
        let inside = f.source.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try initialState(source: f.source, managedRoot: inside) }
    }

    @Test func testProcessLockIsExclusiveAndReleased() throws {
        let f = try Fixture()
        let url = f.root.appendingPathComponent("sync.lock")
        var first: ProcessLock? = try ProcessLock(url: url)
        #expect(first != nil)
        #expect(throws: (any Error).self) { try ProcessLock(url: url) }
        first = nil
        let next = try ProcessLock(url: url)
        withExtendedLifetime(next) {}
    }

    @Test func testEnumerationSkipsSymbolicLinksAndInternalTemporaryPaths() throws {
        let f = try Fixture()
        try f.incoming("visible.txt")
        let outside = f.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("external.txt"), withDestinationURL: outside)
        try Data("temporary".utf8).write(to: f.source.appendingPathComponent(temporaryPrefix + "pending"))
        let inventory = try allFiles(f.source)
        #expect(Set(inventory.keys) == ["visible.txt"])
    }
}
