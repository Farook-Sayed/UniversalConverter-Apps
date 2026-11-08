import XCTest
import ConverterCore

final class ProcessRunnerTests: XCTestCase {

    func testCancellingStopsTheProgramQuickly() async throws {
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let started = Date()
        let task = Task {
            try await ProcessRunner.run(sleep, arguments: ["30"])
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "a cancelled program should not run to the end")
    }

    func testTimeoutGivesAClearError() async throws {
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let started = Date()
        do {
            _ = try await ProcessRunner.run(sleep, arguments: ["30"], timeout: 1)
            XCTFail("the program should have been stopped")
        } catch let error as ConversionError {
            guard case .timedOut(let tool) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(tool, "sleep")
            XCTAssertTrue(error.localizedDescription.contains("took too long"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testOutputWithInvalidUTF8IsStillCaptured() async throws {
        let printf = URL(fileURLWithPath: "/usr/bin/printf")
        let result = try await ProcessRunner.run(printf, arguments: ["ok \\377 done"])
        XCTAssertTrue(result.stdout.contains("ok"))
        XCTAssertTrue(result.stdout.contains("done"))
    }

    func testDefaultTimeoutIsLongEnoughForBigVideos() {
        XCTAssertGreaterThanOrEqual(ProcessRunner.defaultTimeout, 3 * 60 * 60)
    }

    func testOutputIsCaptured() async throws {
        let echo = URL(fileURLWithPath: "/bin/echo")
        let result = try await ProcessRunner.run(echo, arguments: ["hello from the test"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello from the test")
    }
}
