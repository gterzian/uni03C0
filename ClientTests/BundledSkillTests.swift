import XCTest
@testable import Core

/// Tests for `BundledSkill` — the launch-time installer that copies app-bundled
/// skills into pi's user skills directory (`~/.pi/agent/skills`). The install
/// path is FIXED so the skill's `<location>` (and thus the provider's cached
/// system-prompt prefix) never moves; these tests pin that layout and the
/// idempotent, never-clobber behavior. No pi process is spawned.
final class BundledSkillTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var agentDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundledSkillTests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Bundle/Skills", isDirectory: true)
        agentDir = root.appendingPathComponent("agent", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func writeSkill(_ text: String, named name: String, into directory: URL) throws {
        let dir = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func skillText(name: String = "file-reference-links", body: String = "body") -> String {
        "---\nname: \(name)\ndescription: test\n---\n\n\(body)\n"
    }

    private func installedURL(named name: String) -> URL {
        agentDir
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    private var agentSkillsDir: URL {
        agentDir.appendingPathComponent("skills", isDirectory: true)
    }

    // MARK: - Installation

    func testInstallsMissingSkillAtStablePath() throws {
        let text = skillText()
        try writeSkill(text, named: "file-reference-links", into: source)

        XCTAssertTrue(BundledSkill.install(from: source, agentDir: agentDir))

        XCTAssertEqual(try String(contentsOf: installedURL(named: "file-reference-links"), encoding: .utf8), text)
    }

    func testInstallPathIsUnderAgentSkillsDirectory() throws {
        // The whole point: a fixed location under ~/.pi/agent/skills/<name>/
        // SKILL.md. A path into the app bundle (DerivedData/Applications) would
        // move between builds and break the prompt cache.
        try writeSkill(skillText(), named: "file-reference-links", into: source)
        _ = BundledSkill.install(from: source, agentDir: agentDir)
        let expected = agentDir
            .appendingPathComponent("skills/file-reference-links/SKILL.md").path
        XCTAssertEqual(installedURL(named: "file-reference-links").path, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
    }

    func testInstallIsIdempotent() throws {
        try writeSkill(skillText(), named: "file-reference-links", into: source)
        XCTAssertTrue(BundledSkill.install(from: source, agentDir: agentDir))

        let first = try FileManager.default.attributesOfItem(
            atPath: installedURL(named: "file-reference-links").path
        )[.modificationDate] as? Date

        XCTAssertTrue(BundledSkill.install(from: source, agentDir: agentDir), "second install still reports success")

        let second = try FileManager.default.attributesOfItem(
            atPath: installedURL(named: "file-reference-links").path
        )[.modificationDate] as? Date
        XCTAssertEqual(first, second, "an identical skill is not rewritten")
    }

    func testUpdatesAnOlderBundledVersion() throws {
        // Same skill name (an older app version) → the bundled version wins.
        try writeSkill(skillText(body: "old"), named: "file-reference-links", into: agentSkillsDir)
        try writeSkill(skillText(body: "new"), named: "file-reference-links", into: source)

        XCTAssertTrue(BundledSkill.install(from: source, agentDir: agentDir))

        let installed = try String(contentsOf: installedURL(named: "file-reference-links"), encoding: .utf8)
        XCTAssertTrue(installed.contains("new"))
        XCTAssertFalse(installed.contains("old"))
    }

    func testDoesNotClobberADifferentSkillOccupyingTheName() throws {
        // The user's own skill with the same directory name but a different
        // frontmatter name must be left untouched.
        let userSkill = skillText(name: "my-own-skill", body: "mine")
        try writeSkill(userSkill, named: "file-reference-links", into: agentSkillsDir)
        try writeSkill(skillText(body: "bundled"), named: "file-reference-links", into: source)

        XCTAssertFalse(BundledSkill.install(from: source, agentDir: agentDir), "a refused clobber reports failure")

        let installed = try String(contentsOf: installedURL(named: "file-reference-links"), encoding: .utf8)
        XCTAssertEqual(installed, userSkill)
    }

    func testIgnoresFilesAndDirectoriesWithoutSkillFile() throws {
        try writeSkill(skillText(), named: "file-reference-links", into: source)
        try "not a skill".write(
            to: source.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("empty-dir", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertTrue(BundledSkill.install(from: source, agentDir: agentDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL(named: "file-reference-links").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL(named: "README.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL(named: "empty-dir").path))
    }

    func testInstallsEveryBundledSkill() throws {
        try writeSkill(skillText(name: "alpha"), named: "alpha", into: source)
        try writeSkill(skillText(name: "beta"), named: "beta", into: source)

        XCTAssertTrue(BundledSkill.install(from: source, agentDir: agentDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL(named: "alpha").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL(named: "beta").path))
    }

    func testMissingSourceDirectoryReportsFailure() {
        XCTAssertFalse(
            BundledSkill.install(
                from: root.appendingPathComponent("nope", isDirectory: true),
                agentDir: agentDir
            )
        )
    }

    // MARK: - Frontmatter

    func testFrontmatterNameParsesQuotedAndBareNames() {
        XCTAssertEqual(BundledSkill.frontmatterName(in: "---\nname: file-reference-links\n---\n"), "file-reference-links")
        XCTAssertEqual(BundledSkill.frontmatterName(in: "---\nname: \"quoted\"\n---\n"), "quoted")
        XCTAssertNil(BundledSkill.frontmatterName(in: "no frontmatter"), "a file without a leading --- block has no name")
        XCTAssertNil(BundledSkill.frontmatterName(in: "---\ndescription: x\n---\n"), "no name key → nil")
    }

    func testSameSkillComparesFrontmatterNamesOnly() {
        XCTAssertTrue(BundledSkill.sameSkill(skillText(name: "a", body: "1"), skillText(name: "a", body: "2")))
        XCTAssertFalse(BundledSkill.sameSkill(skillText(name: "a"), skillText(name: "b")))
        XCTAssertFalse(BundledSkill.sameSkill("plain", skillText(name: "a")), "an unparseable file is never considered the same skill")
    }
}
