import Testing
@testable import SyncCore

struct CommandTests {
    @Test func supportedCommandsAreExplicit() throws {
        #expect(try Command.parse([]) == .background)
        #expect(try Command.parse(["--list-accounts"]).readOnly)
        #expect(try Command.parse(["--check"]).readOnly)
        #expect(try Command.parse(["--pause-account", "uuid"]) == .pauseAccount("uuid"))
        #expect(try Command.parse(["--resume-account", "uuid"]) == .resumeAccount("uuid"))
        #expect(try Command.parse(["--remove-account", "uuid"]) == .removeAccount("uuid"))
        #expect(try Command.parse(["--restore-account", "uuid"]) == .restoreAccount("uuid"))
        #expect(try Command.parse(["--reauthorize-account", "uuid"]) == .reauthorizeAccount("uuid"))
        #expect(try Command.parse(["--add-account", "--name", "工作"]) == .addAccount("工作"))
        #expect(try Command.parse(["--rename-account", "uuid", "--name", "新名"]) == .renameAccount("uuid", "新名"))
        #expect(try !Command.parse(["--diagnose"]).readOnly)
    }

    @Test(arguments: [["--unknown"], ["--pause-account"], ["--add-account", "--name"],
                      ["--self-test", "--configure"], ["--remove-account", "--check"], ["--check", "extra"],
                      ["--rename-account", "id", "新名"]])
    func invalidCommandsNeverFallThroughToBackground(_ arguments: [String]) throws {
        #expect(throws: (any Error).self) { try Command.parse(arguments) }
    }
}
