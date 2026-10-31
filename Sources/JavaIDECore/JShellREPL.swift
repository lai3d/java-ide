import Foundation

/// An interactive `jshell` session over pipes (stdout and stderr merged so the transcript reads
/// like a terminal). Without a tty jshell falls back to a plain line reader, which is what we want.
public final class JShellREPL: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (String) -> Void
    public typealias ExitHandler = @Sendable (Int32) -> Void

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var _onOutput: OutputHandler?
    private var _onExit: ExitHandler?

    public init() {}

    public var onOutput: OutputHandler? {
        get { lock.withLock { _onOutput } }
        set { lock.withLock { _onOutput = newValue } }
    }

    public var onExit: ExitHandler? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    /// Arguments for jshell: the project's compiled classes on the class path, so its types can be used.
    public static func arguments(classPath: [URL]) -> [String] {
        let existing = classPath.filter { FileManager.default.fileExists(atPath: $0.path) }
        var args = ["--feedback", "normal", "-J-Dfile.encoding=UTF-8", "-R-Dfile.encoding=UTF-8"]
        if !existing.isEmpty {
            args += ["--class-path", existing.map(\.path).joined(separator: ":")]
        }
        return args
    }

    public func start(jshell: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) throws {
        let p = Process()
        p.executableURL = jshell
        p.arguments = arguments
        p.environment = environment
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }

        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.onOutput?(String(decoding: data, as: UTF8.self))
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let handler = self.lock.withLock {
                self.process = nil
                self.stdin = nil
                return self._onExit
            }
            handler?(proc.terminationStatus)
        }
        try p.run()
        lock.withLock {
            process = p
            stdin = input.fileHandleForWriting
        }
    }

    /// Sends source text. Each line is fed to jshell as if typed.
    public func send(_ text: String) {
        let data = Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
        lock.withLock { try? stdin?.write(contentsOf: data) }
    }

    /// Ctrl-C: jshell stops the running snippet and stays alive.
    public func interrupt() {
        lock.withLock { process }?.interrupt()
    }

    public func stop() {
        let p = lock.withLock {
            try? stdin?.write(contentsOf: Data("/exit\n".utf8))
            try? stdin?.close()
            stdin = nil
            return process
        }
        if let p, p.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } }
        }
    }

    /// Prepares an editor selection for jshell: trims surrounding blank lines and removes common
    /// indentation (jshell accepts multi-line snippets as long as brackets balance).
    public static func prepareForSending(_ code: String) -> String {
        var lines = code.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        guard !lines.isEmpty else { return "" }
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let common = indents.min() ?? 0
        lines = lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
        return lines.joined(separator: "\n") + "\n"
    }
}
