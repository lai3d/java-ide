import Foundation
import JavaIDECore
import Observation

/// One Run / Build / Test process and its output: a tab in the Output panel. Several can run at once
/// (e.g. the services of a Spring Cloud project).
@MainActor
@Observable
final class RunSession: Identifiable {
    let id = UUID()
    /// Identifies what the session runs ("run:<main class>", "build", "test", "prebuild").
    let key: String
    let title: String
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var exitStatus: Int32?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    /// Called once the process exits (after its last output landed).
    @ObservationIgnored var onExit: (Int32) -> Void = { _ in }

    init(key: String, title: String) {
        self.key = key
        self.title = title
    }

    func start(_ command: RunCommand, directory: URL, environment: [String: String]) {
        guard !isRunning else { return }
        output = "$ \(command.display)\n"
        exitStatus = nil
        isRunning = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.shell]
        process.currentDirectoryURL = directory
        process.environment = environment
        let pipe = Pipe(), input = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = input
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(chunk) }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                // Let any final output chunks land first.
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.isRunning = false
                self.exitStatus = status
                self.process = nil
                try? self.input?.close()
                self.input = nil
                self.append("\n[process exited with status \(status)]\n")
                self.onExit(status)
            }
        }
        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
        } catch {
            isRunning = false
            append("Failed to start: \(error.localizedDescription)\n")
        }
    }

    /// Shows a message instead of running anything.
    func show(_ message: String) {
        guard !isRunning else { return }
        output = message
    }

    func stop() {
        guard let process else { return }
        // Commands `exec` the final tool, so SIGINT reaches the JVM / Maven / Gradle directly.
        process.interrupt()
        Task {
            try? await Task.sleep(for: .seconds(3))
            if process.isRunning { process.terminate() }
        }
    }

    /// Sends a line to the program's stdin (for `Scanner` / `readLine`), echoing it in the output.
    func send(_ line: String) {
        guard let input else { return }
        append(line + "\n")
        try? input.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Closes the program's stdin (Ctrl-D).
    func sendEOF() {
        try? input?.close()
        input = nil
    }

    func clear() { output = "" }

    func append(_ s: String) {
        output += s
        if output.utf16.count > 1_000_000 { output = String(output.suffix(800_000)) }
    }
}
