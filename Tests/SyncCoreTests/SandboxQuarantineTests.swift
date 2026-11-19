import Foundation
import Darwin
import Testing
@testable import SyncCore

struct SandboxQuarantineTests {
    private func quarantine(_ file: URL, _ data: Data, noFollow: Bool = false) throws {
        try systemCall(data.withUnsafeBytes { setxattr(file.path, "com.apple.quarantine", $0.baseAddress, data.count, 0, noFollow ? XATTR_NOFOLLOW : 0) }, "设置临时隔离属性")
    }
    private func archived(_ f: ContentFixture, quarantine data: Data) throws -> URL {
        let file = try f.files.incoming(0, "first.txt", text: "same")
        try quarantine(file, data)
        try f.worker.scan(); try f.worker.scan()
        return URL(fileURLWithPath: try #require(linkTarget(file.path)))
    }

    @Test func canonicalOnlyQuarantineDoesNotBlockDedupOrLoseProtection() throws {
        let f = try ContentFixture()
        let data = Data("0083;00000001;TestAgent;".utf8)
        let target = try archived(f, quarantine: data)
        let second = try f.files.incoming(0, "second.txt", text: "same")
        try f.worker.scan(); try f.worker.scan()
        #expect(fileInfo(second.path)?.symbolicLink == true)
        #expect(linkTarget(second.path) == target.path)
        #expect(try OpenedContent(target).attributes()["com.apple.quarantine"] == data)
        #expect((fileInfo(target.path)?.mode ?? 0) & 0o222 == 0)
        #expect(try f.store.entities(f.a.id).count == 1)
        #expect(try f.store.sources(f.a.id).filter { $0.status == .linked }.count == 2)
    }

    @Test func differentSourceQuarantineIsRetainedAndNotMerged() throws {
        let f = try ContentFixture()
        let firstData = Data("0083;00000001;FirstAgent;".utf8)
        let secondData = Data("0083;00000002;SecondAgent;".utf8)
        let target = try archived(f, quarantine: firstData)
        let second = try f.files.incoming(0, "second.txt", text: "same")
        try quarantine(second, secondData)
        try f.worker.scan(); try f.worker.scan()
        #expect(fileInfo(second.path)?.regular == true)
        #expect(try OpenedContent(second).attributes()["com.apple.quarantine"] == secondData)
        #expect(try OpenedContent(target).attributes()["com.apple.quarantine"] == firstData)
        #expect(try f.store.entities(f.a.id).count == 1)
    }

    @Test func equalQuarantineCanBeSharedWithoutChangingIt() throws {
        let f = try ContentFixture()
        let data = Data("0083;00000001;TestAgent;".utf8)
        let target = try archived(f, quarantine: data)
        let second = try f.files.incoming(0, "second.txt", text: "same")
        try quarantine(second, data)
        try f.worker.scan(); try f.worker.scan()
        #expect(fileInfo(second.path)?.symbolicLink == true)
        #expect(linkTarget(second.path) == target.path)
        #expect(try OpenedContent(target).attributes()["com.apple.quarantine"] == data)
    }
    @Test(arguments: [false, true])
    func ownPreparedLinkQuarantineSurvivesSwapAndRestart(_ interrupt: Bool) throws {
        weak var current: ContentFixture?
        let generated = Data("0082;00000002;OurPreparedLink;".utf8)
        let original = Data("0083;00000001;Canonical;".utf8)
        var didInterrupt = false
        let f = try ContentFixture(checkpoint: { stage in
            guard let f = current, let op = try f.store.operations(f.a.id).first(where: { $0.kind == .attach }) else { return }
            let temp = f.files.sources[0].appendingPathComponent(op.temporary)
            if stage == .planSaved {
                let entity = try #require(f.store.entities(f.a.id).first(where: { $0.id == op.entityID }))
                let target = f.files.root.appendingPathComponent(entity.relative)
                try systemCall(symlink(target.path, temp.path), "模拟沙盒准备链接")
                try self.quarantine(temp, generated, noFollow: true)
            } else if stage == .swapped {
                #expect(op.swappedQuarantine == generated)
                try self.quarantine(temp, generated)
                if interrupt && !didInterrupt { didInterrupt = true; throw SyncError.message("模拟交换后中断") }
            }
        })
        current = f
        let target = try archived(f, quarantine: original)
        let second = try f.files.incoming(0, "second.txt", text: "same")
        try f.worker.scan(); try f.worker.scan()
        if interrupt { f.restart(); try f.worker.scan() }
        #expect(fileInfo(second.path)?.symbolicLink == true)
        #expect(linkTarget(second.path) == target.path)
        #expect(try OpenedContent(target).attributes()["com.apple.quarantine"] == original)
        #expect(try f.store.operations(f.a.id).isEmpty)
    }

    @Test(arguments: [false, true])
    func unknownOrChangedSwapQuarantinePreservesDuplicate(_ legacyWithoutMarker: Bool) throws {
        weak var current: ContentFixture?
        let generated = Data("0082;00000002;OurPreparedLink;".utf8)
        let changed = Data("0083;00000003;ExternalChange;".utf8)
        let original = Data("0083;00000001;Canonical;".utf8)
        let f = try ContentFixture(checkpoint: { stage in
            guard let f = current, var op = try f.store.operations(f.a.id).first(where: { $0.kind == .attach }) else { return }
            let temp = f.files.sources[0].appendingPathComponent(op.temporary)
            if stage == .planSaved {
                let entity = try #require(f.store.entities(f.a.id).first(where: { $0.id == op.entityID }))
                try systemCall(symlink(f.files.root.appendingPathComponent(entity.relative).path, temp.path), "模拟准备链接")
                try self.quarantine(temp, generated, noFollow: true)
            } else if stage == .swapped {
                try self.quarantine(temp, legacyWithoutMarker ? generated : changed)
                if legacyWithoutMarker {
                    op.swappedQuarantine = nil
                    try f.store.atomic { try f.store.put(op) }
                    throw SyncError.message("模拟旧版操作未记录隔离标记")
                }
            }
        })
        current = f
        let target = try archived(f, quarantine: original)
        let second = try f.files.incoming(0, "second.txt", text: "same")
        try f.worker.scan(); try f.worker.scan()
        if legacyWithoutMarker { f.restart(); try f.worker.scan() }
        #expect(fileInfo(second.path)?.regular == true)
        #expect(try String(contentsOf: second, encoding: .utf8) == "same")
        #expect(try OpenedContent(second).attributes()["com.apple.quarantine"] == (legacyWithoutMarker ? generated : changed))
        #expect(try OpenedContent(target).attributes()["com.apple.quarantine"] == original)
    }

}
