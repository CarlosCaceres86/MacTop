import Darwin
import Foundation
import XCTest

@testable import MacTopSystem

final class HelperProcessTests: XCTestCase {
  func testImmediateFailurePreservesOutputAndExitStatus() async throws {
    let reply = try await HelperProcess.run(
      url: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf 'complete output'; exit 17"])
    XCTAssertEqual(reply.data, Data("complete output".utf8))
    XCTAssertEqual(reply.status, 17)
    XCTAssertFalse(reply.timedOut)
  }

  func testLargeOutputIsFullyReadAfterSuccessfulExit() async throws {
    let reply = try await HelperProcess.run(
      url: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "i=0; while [ \"$i\" -lt 20000 ]; do printf 'inventory-row\\n'; i=$((i+1)); done"])
    XCTAssertEqual(reply.data, Data(String(repeating: "inventory-row\n", count: 20000).utf8))
    XCTAssertEqual(reply.status, 0)
    XCTAssertFalse(reply.timedOut)
  }

  func testTimeoutKillsAndReapsAProcessThatIgnoresTermination() async throws {
    let reply = try await HelperProcess.run(
      url: URL(fileURLWithPath: "/usr/bin/perl"),
      arguments: ["-e", "$SIG{TERM} = 'IGNORE'; $| = 1; print \"$$\\n\"; sleep 60;"])
    XCTAssertTrue(reply.timedOut)
    XCTAssertEqual(reply.status, SIGKILL)
    let pid = try XCTUnwrap(Int32(String(decoding: reply.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    let probe = kill(pid, 0)
    let probeError = errno
    XCTAssertEqual(probe, -1, "The child must already have been reaped")
    XCTAssertEqual(probeError, ESRCH)
  }
}
