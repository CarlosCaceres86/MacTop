import Darwin
import Foundation

enum SystemFailure: LocalizedError {
  case unavailable(String)
  case changed(String)
  case partial(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let reason), .changed(let reason), .partial(let reason): return reason
    }
  }
}

struct HelperReply: Sendable {
  let data: Data
  let status: Int32
  let timedOut: Bool
}

enum HelperProcess {
  // Files avoid pipe back-pressure for inventories with many windows.
  static func run(url: URL, arguments: [String]) async throws -> HelperReply {
    try await Task.detached { try execute(url: url, arguments: arguments) }.value
  }

  private static func execute(url: URL, arguments: [String]) throws -> HelperReply {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
      throw SystemFailure.unavailable("No se pudo preparar la lectura del componente de Spaces.")
    }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = url
    process.arguments = arguments
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = ProcessInfo.processInfo.systemUptime + 6
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    let timedOut = process.isRunning
    if timedOut {
      process.terminate()
      let grace = ProcessInfo.processInfo.systemUptime + 0.5
      while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    // Foundation has already observed termination when isRunning is false.
    if process.isRunning { process.waitUntilExit() }
    return HelperReply(
      data: try Data(contentsOf: output), status: process.terminationStatus, timedOut: timedOut)
  }
}
