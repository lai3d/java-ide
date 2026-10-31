import Foundation

/// A minimal Debug Adapter Protocol client over stdio or a TCP socket (same `Content-Length` framing as LSP).
public final class DAPClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (_ event: String, _ body: JSONValue) -> Void
    public typealias ExitHandler = @Sendable (_ status: Int32) -> Void
    /// Answers a reverse request (e.g. `runInTerminal`): return the response body, or nil to decline.
    public typealias ReverseRequestHandler = @Sendable (_ command: String, _ arguments: JSONValue) throws -> JSONValue?

    public enum ClientError: Error, LocalizedError {
        case notRunning
        case failed(command: String, message: String)

        public var errorDescription: String? {
            switch self {
            case .notRunning: "debug adapter is not running"
            case .failed(let command, let message): "\(command) failed: \(message)"
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    /// For TCP connections: the socket handle (both directions).
    private var socket: FileHandle?
    private var framer = LSPFramer()
    private var nextSeq = 1
    private var pending: [Int: (command: String, continuation: CheckedContinuation<JSONValue, any Error>)] = [:]
    private var _onEvent: EventHandler?
    private var _onExit: ExitHandler?
    private var _onReverseRequest: ReverseRequestHandler?
    private var stderrText = ""

    public init() {}

    /// Called (on a background thread) for every adapter event.
    public var onEvent: EventHandler? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    public var onExit: ExitHandler? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    public var onReverseRequest: ReverseRequestHandler? {
        get { lock.withLock { _onReverseRequest } }
        set { lock.withLock { _onReverseRequest = newValue } }
    }

    /// Adapter stderr so far (useful when it fails to start).
    public var stderrOutput: String { lock.withLock { stderrText } }

    public func start(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = environment
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.receive(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock { if self.stderrText.count < 20_000 { self.stderrText += text } }
        }
        p.terminationHandler = { [weak self] proc in self?.handleExit(proc.terminationStatus) }
        try p.run()
        lock.withLock {
            process = p
            stdin = inPipe.fileHandleForWriting
        }
    }

    /// Connects to an adapter listening on `host:port` (java-debug, started inside jdtls).
    public func connect(host: String = "127.0.0.1", port: Int) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.failed(command: "connect", message: String(cString: strerror(errno))) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw ClientError.failed(command: "connect", message: "\(host):\(port): \(message)")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.handleExit(0)
                return
            }
            self?.receive(data)
        }
        lock.withLock {
            socket = handle
            stdin = handle
        }
    }

    /// Sends a request and waits for its response body. Throws if `success` is false.
    public func request(_ command: String, arguments: JSONValue = .null) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let seq: Int = lock.withLock {
                let seq = nextSeq
                nextSeq += 1
                pending[seq] = (command, continuation)
                return seq
            }
            var message: [String: JSONValue] = ["seq": .int(seq), "type": "request", "command": .string(command)]
            if !arguments.isNull { message["arguments"] = arguments }
            do {
                try send(.object(message))
            } catch {
                if let entry = lock.withLock({ pending.removeValue(forKey: seq) }) {
                    entry.continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sends a request without waiting for the response.
    public func send(_ command: String, arguments: JSONValue = .null) {
        Task { _ = try? await request(command, arguments: arguments) }
    }

    public func terminate() {
        let (p, socket) = lock.withLock { (process, self.socket) }
        if let p, p.isRunning { p.terminate() }
        if let socket {
            socket.readabilityHandler = nil
            try? socket.close()
            handleExit(0)
        }
    }

    // MARK: - Private

    private func send(_ message: JSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = LSPFramer.frame(try encoder.encode(message))
        try lock.withLock {
            guard let stdin else { throw ClientError.notRunning }
            try stdin.write(contentsOf: data)
        }
    }

    private func receive(_ data: Data) {
        let bodies = lock.withLock { framer.append(data) }
        let decoder = JSONDecoder()
        for body in bodies {
            guard let message = try? decoder.decode(JSONValue.self, from: body) else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: JSONValue) {
        switch message["type"]?.stringValue {
        case "response":
            guard let seq = message["request_seq"]?.intValue,
                  let entry = lock.withLock({ pending.removeValue(forKey: seq) }) else { return }
            if message["success"]?.boolValue == true {
                entry.continuation.resume(returning: message["body"] ?? .null)
            } else {
                let detail = message["body"]?["error"]?["format"]?.stringValue
                    ?? message["message"]?.stringValue ?? "unknown error"
                entry.continuation.resume(throwing: ClientError.failed(command: entry.command, message: detail))
            }
        case "event":
            guard let event = message["event"]?.stringValue else { return }
            onEvent?(event, message["body"] ?? .null)
        case "request":
            // Reverse requests (e.g. runInTerminal).
            guard let seq = message["seq"]?.intValue, let command = message["command"]?.stringValue else { return }
            var response: [String: JSONValue] = ["seq": 0, "type": "response", "request_seq": .int(seq),
                                                 "command": .string(command)]
            do {
                if let body = try onReverseRequest?(command, message["arguments"] ?? .null) {
                    response["success"] = true
                    response["body"] = body
                } else {
                    response["success"] = false
                    response["message"] = "not supported"
                }
            } catch {
                response["success"] = false
                response["message"] = .string(error.localizedDescription)
            }
            try? send(.object(response))
        default:
            break
        }
    }

    private func handleExit(_ status: Int32) {
        let (waiters, handler) = lock.withLock {
            let waiters = pending.values.map(\.continuation)
            pending.removeAll()
            stdin = nil
            process = nil
            socket = nil
            let handler = _onExit
            _onExit = nil  // report the end once (socket EOF and terminate() can both get here)
            return (waiters, handler)
        }
        for waiter in waiters { waiter.resume(throwing: ClientError.notRunning) }
        handler?(status)
    }
}

// MARK: - Models

public struct StackFrameInfo: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let path: String?
    /// 1-based, as DAP sends with `linesStartAt1`.
    public let line: Int

    public init(id: Int, name: String, path: String?, line: Int) {
        self.id = id
        self.name = name
        self.path = path
        self.line = line
    }

    public static func parseAll(_ body: JSONValue) -> [StackFrameInfo] {
        (body["stackFrames"]?.arrayValue ?? []).compactMap { frame in
            guard let id = frame["id"]?.intValue, let name = frame["name"]?.stringValue else { return nil }
            return StackFrameInfo(id: id, name: name, path: frame["source"]?["path"]?.stringValue,
                                  line: frame["line"]?.intValue ?? 0)
        }
    }
}

public struct VariableInfo: Sendable, Hashable, Identifiable {
    public let name: String
    public let value: String
    public let type: String?
    /// > 0 when the value has children (fetch them with `variables`).
    public let reference: Int
    public var id: String { "\(reference)-\(name)" }

    public init(name: String, value: String, type: String?, reference: Int) {
        self.name = name
        self.value = value
        self.type = type
        self.reference = reference
    }

    /// Parses a `scopes` body (as pseudo-variables) or a `variables` body.
    public static func parseAll(_ body: JSONValue) -> [VariableInfo] {
        let items = body["variables"]?.arrayValue ?? body["scopes"]?.arrayValue ?? []
        return items.compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            return VariableInfo(name: name, value: item["value"]?.stringValue ?? "",
                                type: item["type"]?.stringValue,
                                reference: item["variablesReference"]?.intValue ?? 0)
        }
    }
}

/// The java-debug plugin (Microsoft's debug adapter, loaded into jdtls as an OSGi bundle).
public enum JavaDebugLocator {
    public static let version = "0.53.1"
    /// SHA-1 published on Maven Central for the jar above.
    public static let sha1 = "dfc433d62cbb5bb71cfe87f1ee5363c549dccc92"

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JavaIDE/java-debug")
    }

    public static var jarName: String { "com.microsoft.java.debug.plugin-\(version).jar" }

    public static var jar: URL { supportDirectory.appendingPathComponent(jarName) }

    public static var downloadURL: URL {
        URL(string: "https://repo1.maven.org/maven2/com/microsoft/java/com.microsoft.java.debug.plugin/\(version)/\(jarName)")!
    }

    /// Any java-debug jar already installed (the bundled version, or one the user dropped in).
    public static var installedJar: URL? {
        if FileManager.default.fileExists(atPath: jar.path) { return jar }
        let items = (try? FileManager.default.contentsOfDirectory(at: supportDirectory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("com.microsoft.java.debug.plugin") && $0.pathExtension == "jar" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }

    public struct DownloadError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Downloads the jar from Maven Central into the support folder, checking its SHA-1.
    public static func install() async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DownloadError(message: "download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let data = try Data(contentsOf: temporary)
        guard SHA1.hex(data) == sha1 else { throw DownloadError(message: "checksum mismatch for \(jarName)") }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: jar)
        try data.write(to: jar, options: .atomic)
        return jar
    }
}

/// Minimal SHA-1 (only for verifying downloads against Maven Central's published checksums).
public enum SHA1 {
    public static func hex(_ data: Data) -> String {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() { message.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xFF)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(message[b]) << 24 | UInt32(message[b + 1]) << 16 | UInt32(message[b + 2]) << 8 | UInt32(message[b + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (x << 1) | (x >> 31)
            }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32) = switch i {
                case 0..<20: ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (b ^ c ^ d, 0xCA62C1D6)
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, (b << 30) | (b >> 2), a, temp)
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
