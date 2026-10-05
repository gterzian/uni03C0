import XCTest
@testable import Core

/// End-to-end checks against a real throwaway git repository. A branch switch
/// is exactly what makes a pinned session baseline stale — the viewer then diffs
/// the working tree against a commit on ANOTHER branch and shows the whole
/// cross-branch delta — and the branch name is the only signal that tells a
/// switch apart from the same-branch commit the viewer must survive.
final class GitStatusBranchTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitstatus-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try git("config", "commit.gpgsign", "false")
        try write("a.txt", "one\n")
        try git("add", "a.txt")
        try git("commit", "-q", "-m", "base")
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        repo = nil
    }

    func testBranchSwitchIsDetectableAndMakesThePinnedBaselineStale() async throws {
        let mainHead = try git("rev-parse", "HEAD")

        try git("checkout", "-q", "-b", "feature")
        try write("feature.txt", "two\n")
        try git("add", "feature.txt")
        try git("commit", "-q", "-m", "feature work")

        let feature = await GitStatus.resolveBranch(at: repo)
        XCTAssertEqual(feature, "feature")

        // With the baseline pinned to main's commit while HEAD is on feature,
        // the viewer reports the cross-branch delta as "changes" — the bug.
        let pinnedToMain = await GitStatus.classify(at: repo, base: mainHead)
        XCTAssertTrue(pinnedToMain.contains { $0.path == "feature.txt" })

        // Checking out main changes the branch name, which is the re-pin
        // signal, and diffing against main's own commit is clean again.
        try git("checkout", "-q", "main")
        let back = await GitStatus.resolveBranch(at: repo)
        XCTAssertEqual(back, "main")
        XCTAssertTrue(GitStatus.shouldRepinBaseline(hasBaseline: true, pinnedBranch: feature, currentBranch: back))

        let rePinnedHead = try git("rev-parse", "HEAD")
        let clean = await GitStatus.classify(at: repo, base: rePinnedHead)
        XCTAssertFalse(clean.contains { $0.path == "feature.txt" })
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitStatusBranchTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"]
            )
        }
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
