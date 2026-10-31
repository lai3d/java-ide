import AppKit
import JavaIDECore
import Observation

enum BottomTab: Hashable {
    case problems, output, references, repl, debug
}

/// Where a paused debugger is (normalized path, zero-based line).
struct ExecutionLocation: Equatable {
    let key: String
    let line: Int
}

/// One result of Find References, with its source line for context.
struct ReferenceItem: Identifiable {
    let id = UUID()
    let url: URL
    let position: TextPosition
    let lineText: String
    var fileName: String { url.lastPathComponent }
}

/// A request for the editor to move the caret to a position.
struct RevealTarget: Equatable {
    let id = UUID()
    let position: TextPosition
}

struct NavigationPoint: Equatable {
    let url: URL
    let position: TextPosition
}

struct ProblemItem: Identifiable {
    let path: String
    let diagnostic: Diagnostic
    var id: UUID { diagnostic.id }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// A file open in an editor tab.
struct OpenDocument: Identifiable {
    let url: URL
    var text: String
    var isDirty = false
    var version = 1
    /// For decompiled / attached library sources: the `jdt://` URI the language server knows them by.
    var lspURI: String?
    /// Normalized path; the identity used for tabs, diagnostics and editor state.
    var id: String { Workspace.key(for: url) }
    var name: String { url.lastPathComponent }
    var uri: String { lspURI ?? url.absoluteString }
}

/// The run-menu actions.
enum RunAction {
    case run, test, build
}

/// All state for one open project folder: files, editor buffers, jdtls, and build/run processes.
@MainActor
@Observable
final class Workspace {
    private(set) var rootURL: URL?
    private(set) var fileTree: [FileNode] = []
    private(set) var documents: [OpenDocument] = []
    private(set) var currentFile: URL? {
        didSet { if oldValue != currentFile { scheduleOutlineRefresh(after: .zero) } }
    }
    /// Symbols of the current file for the Outline sidebar.
    private(set) var outline: [OutlineSymbol] = []
    @ObservationIgnored private var outlineTask: Task<Void, Never>?
    @ObservationIgnored private var fileWatcher: FileWatcher?
    private(set) var diagnostics: [String: [Diagnostic]] = [:]  // keyed by normalized path
    private(set) var lspStatus = "Language server: not started"
    private(set) var jdk: JDK?
    private(set) var buildSystem: BuildSystem = .plain
    private(set) var output = ""
    private(set) var isRunning = false
    var bottomTab: BottomTab = .problems
    /// Format with jdtls on ⌘S. Persisted across launches.
    var formatOnSave: Bool = UserDefaults.standard.object(forKey: "formatOnSave") as? Bool ?? false {
        didSet { UserDefaults.standard.set(formatOnSave, forKey: "formatOnSave") }
    }
    /// Organize imports on ⌘S. Persisted across launches.
    var organizeImportsOnSave: Bool = UserDefaults.standard.object(forKey: "organizeImportsOnSave") as? Bool ?? false {
        didSet { UserDefaults.standard.set(organizeImportsOnSave, forKey: "organizeImportsOnSave") }
    }
    var revealTarget: RevealTarget?
    /// Set by the Code ▸ Show Quick Fixes command; the editor shows the menu at the caret.
    var quickFixRequest: UUID?
    private(set) var backStack: [NavigationPoint] = []
    private(set) var references: [ReferenceItem] = []
    private(set) var referencesQuery = ""
    /// UTF-16 caret offset in the current file, reported by the editor.
    @ObservationIgnored var caretOffset = 0
    /// Current editor selection (UTF-16), reported by the editor.
    @ObservationIgnored var selectedRange = NSRange(location: 0, length: 0)

    /// Breakpoints per normalized path: zero-based line → condition ("" when unconditional).
    private(set) var breakpoints: [String: [Int: String]] = [:]
    private(set) var debugSession: DebugSession?
    private(set) var executionLocation: ExecutionLocation?

    private(set) var replOutput = ""
    private(set) var isREPLRunning = false
    @ObservationIgnored private var repl: JShellREPL?

    @ObservationIgnored private var lsp: LSPClient?
    @ObservationIgnored private var lspReady = false
    /// jdtls finished importing the project (`language/status` ServiceReady).
    @ObservationIgnored private var lspServiceReady = false
    /// Whether the running jdtls was started with the java-debug bundle.
    @ObservationIgnored private var lspHasDebugBundle = false
    @ObservationIgnored private var runProcess: Process?
    @ObservationIgnored private var runInput: FileHandle?
    @ObservationIgnored private var handledLaunchArguments = false

    var currentDiagnostics: [Diagnostic] {
        guard let currentFile else { return [] }
        return diagnostics[Self.key(for: currentFile)] ?? []
    }

    var allProblems: [ProblemItem] {
        diagnostics.keys.sorted().flatMap { path in
            diagnostics[path, default: []].map { ProblemItem(path: path, diagnostic: $0) }
        }
    }

    private var currentIndex: Int? {
        guard let currentFile else { return nil }
        let key = Self.key(for: currentFile)
        return documents.firstIndex { $0.id == key }
    }

    private var currentDocument: OpenDocument? { currentIndex.map { documents[$0] } }

    var text: String { currentIndex.map { documents[$0].text } ?? "" }
    var currentVersion: Int { currentIndex.map { documents[$0].version } ?? 0 }
    var isDirty: Bool { currentIndex.map { documents[$0].isDirty } ?? false }
    var hasUnsavedChanges: Bool { documents.contains { $0.isDirty } }
    var currentDocumentID: String { currentFile.map(Self.key(for:)) ?? "" }

    var isJavaFile: Bool { currentFile.map(Self.isJava) ?? false }

    /// Files outside the project (JDK and library sources) are opened read-only.
    var isReadOnly: Bool { currentFile.map(isReadOnly) ?? false }

    func isReadOnly(_ url: URL) -> Bool {
        guard let rootURL else { return false }
        let path = Self.key(for: url)
        let root = Self.key(for: rootURL)
        return !path.hasPrefix(root + "/")
    }

    var canGoBack: Bool { !backStack.isEmpty }

    var jdkLabel: String { jdk?.label ?? "No JDK" }

    // MARK: - Folder

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Java project folder (Maven, Gradle, or plain sources)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openFolder(url) }
    }

    /// Opens a folder passed on the command line, e.g. `swift run JavaIDE ./Examples/hello`.
    func handleLaunchArguments() async {
        guard !handledLaunchArguments else { return }
        handledLaunchArguments = true
        for arg in CommandLine.arguments.dropFirst() {
            var isDir: ObjCBool = false
            let url = URL(fileURLWithPath: arg).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                await openFolder(url)
                applyLaunchBreakpoints(root: url)
                return
            }
        }
    }

    /// Dev aid for scripted testing: `JAVAIDE_BREAKPOINTS="Main.java:9,src/A.java:12"` (1-based lines).
    private func applyLaunchBreakpoints(root: URL) {
        guard let spec = ProcessInfo.processInfo.environment["JAVAIDE_BREAKPOINTS"] else { return }
        for item in spec.split(separator: ",") {
            let parts = item.split(separator: ":")
            guard parts.count == 2, let line = Int(parts[1]), line > 0 else { continue }
            let key = Self.key(for: root.appendingPathComponent(String(parts[0])))
            var lines = breakpoints[key] ?? [:]
            lines[line - 1] = ""
            updateBreakpoints(lines, for: key)
        }
    }

    func openFolder(_ url: URL) async {
        guard confirmDiscardOrSave(documents.filter(\.isDirty)) else { return }
        stopDebugging()
        debugSession = nil
        breakpoints = [:]
        stopREPL()
        replOutput = ""
        await stopLanguageServer()
        rootURL = url
        fileTree = FileNode.loadTree(at: url)
        fileWatcher = FileWatcher(url: url, ignoredComponents: FileNode.ignoredNames.union([".git"])) { [weak self] in
            self?.reloadTree()
        }
        if jdk == nil { jdk = JDK.locate() }
        buildSystem = BuildSystem.detect(root: url)
        currentFile = nil
        documents = []
        diagnostics = [:]
        output = ""
        backStack = []
        if let first = Self.firstMainFile(in: fileTree) ?? Self.firstJavaFile(in: fileTree) {
            openFile(first)
        }
        await startLanguageServer(root: url)
    }

    func reloadTree() {
        guard let rootURL else { return }
        fileTree = FileNode.loadTree(at: rootURL)
        let detected = BuildSystem.detect(root: rootURL)
        if detected != buildSystem { buildSystem = detected }
    }

    /// Lets the user pick one of the installed JDKs (or browse for a JDK home).
    func chooseJDK(_ choice: JDK) {
        jdk = choice
        if repl != nil { restartREPL() }
        Task { await restartLanguageServer() }
    }

    func presentJDKPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Use JDK"
        panel.message = "Choose a JDK home (the folder containing bin/javac)"
        panel.directoryURL = URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines")
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Home/bin/javac").path) {
            url = url.appendingPathComponent("Contents/Home")
        }
        let candidate = JDK(home: url)
        guard candidate.isValid else {
            flashStatus("\(url.lastPathComponent) is not a JDK (no bin/javac)")
            return
        }
        chooseJDK(candidate)
    }

    // MARK: - Files

    /// Opens `url` in a tab (or switches to its existing tab).
    func openFile(_ url: URL) {
        let key = Self.key(for: url)
        if documents.contains(where: { $0.id == key }) {
            currentFile = url
            return
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            appendOutput("Cannot open \(url.path) (not UTF-8 text?)\n")
            bottomTab = .output
            return
        }
        open(OpenDocument(url: url, text: contents))
    }

    private func open(_ document: OpenDocument) {
        let insertAt = currentIndex.map { $0 + 1 } ?? documents.count
        documents.insert(document, at: insertAt)
        currentFile = document.url
        caretOffset = 0
        sendDidOpen(document)
    }

    func selectTab(_ document: OpenDocument) {
        currentFile = document.url
    }

    func selectAdjacentTab(_ delta: Int) {
        guard let index = currentIndex, documents.count > 1 else { return }
        let next = (index + delta + documents.count) % documents.count
        currentFile = documents[next].url
    }

    /// Closes a tab, asking to save it first if it has unsaved changes.
    func close(_ document: OpenDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        guard confirmDiscardOrSave([documents[index]]) else { return }
        let closing = documents.remove(at: index)
        sendDidClose(closing)
        diagnostics.removeValue(forKey: closing.id)  // re-published if the file is reopened
        if currentFile.map(Self.key(for:)) == closing.id {
            currentFile = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].url
        }
    }

    func closeCurrentTab() {
        if let index = currentIndex { close(documents[index]) }
    }

    func closeOthers(_ keep: OpenDocument) {
        for document in documents where document.id != keep.id { close(document) }
    }

    func closeAll() {
        for document in documents { close(document) }
    }

    /// File ▸ New Java Class…: creates `Name.java` next to the current file (or in the main source
    /// root) with the right `package` line, and opens it.
    func newJavaClass() {
        guard let rootURL else { return }
        let directory: URL
        if let currentFile, !isReadOnly(currentFile) {
            directory = currentFile.deletingLastPathComponent()
        } else {
            let main = rootURL.appendingPathComponent("src/main/java")
            directory = FileManager.default.fileExists(atPath: main.path) ? main : rootURL
        }
        let alert = NSAlert()
        alert.messageText = "New Java Class"
        alert.informativeText = "In \(relativePath(directory).isEmpty ? rootURL.lastPathComponent : relativePath(directory))"
        let field = NSTextField(string: "")
        field.placeholderString = "ClassName (or interface:Name, enum:Name, record:Name)"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var input = field.stringValue.trimmingCharacters(in: .whitespaces)
        var kind = "class"
        if let colon = input.firstIndex(of: ":") {
            kind = String(input[..<colon]).lowercased()
            input = String(input[input.index(after: colon)...])
        }
        let name = input.hasSuffix(".java") ? String(input.dropLast(5)) : input
        guard Identifier.isValidJavaName(name), ["class", "interface", "enum", "record"].contains(kind) else {
            flashStatus("'\(field.stringValue)' is not a valid class name")
            return
        }
        let file = directory.appendingPathComponent(name + ".java")
        guard !FileManager.default.fileExists(atPath: file.path) else {
            openFile(file)
            return
        }
        var siblingSource: String?
        if let currentFile, currentFile.deletingLastPathComponent() == directory, Self.isJava(currentFile) {
            siblingSource = currentDocument?.text
        }
        let package = Self.packageName(for: directory, root: rootURL, siblingSource: siblingSource)
        let body = kind == "record" ? "public record \(name)() {\n}\n" : "public \(kind) \(name) {\n}\n"
        let source = (package.map { "package \($0);\n\n" } ?? "") + body
        do {
            try source.write(to: file, atomically: true, encoding: .utf8)
            reloadTree()
            openFile(file)
        } catch {
            flashStatus("Could not create \(file.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// The package for a new file: from a sibling's `package` line, else the path below a source root.
    static func packageName(for directory: URL, root: URL, siblingSource: String?) -> String? {
        if let siblingSource { return JavaProject.packageName(in: siblingSource) }
        let path = key(for: directory)
        for marker in ["/src/main/java/", "/src/test/java/", "/src/"] {
            if let range = path.range(of: marker) {
                let rest = path[range.upperBound...]
                return rest.isEmpty ? nil : rest.replacingOccurrences(of: "/", with: ".")
            }
        }
        if path.hasSuffix("/src/main/java") || path.hasSuffix("/src/test/java") || path.hasSuffix("/src") { return nil }
        return nil
    }

    func updateText(_ newText: String) {
        guard let index = currentIndex else { return }
        setText(newText, at: index)
    }

    private func setText(_ newText: String, at index: Int) {
        guard documents[index].text != newText else { return }
        // Keep breakpoints on their code as lines are inserted or deleted.
        let key = documents[index].id
        if let lines = breakpoints[key], !lines.isEmpty {
            let moved = LineShift.remap(lines, old: documents[index].text, new: newText)
            if moved != lines { updateBreakpoints(moved, for: key) }
        }
        documents[index].text = newText
        documents[index].isDirty = documents[index].lspURI == nil
        documents[index].version += 1
        guard lspReady, Self.isJava(documents[index].url) else { return }
        try? lsp?.notify("textDocument/didChange", params: [
            "textDocument": ["uri": .string(documents[index].uri), "version": .int(documents[index].version)],
            "contentChanges": [["text": .string(newText)]],
        ])
        if documents[index].id == currentDocumentID { scheduleOutlineRefresh(after: .milliseconds(500)) }
    }

    /// ⌘S: formats / organizes imports first when those options are on.
    func save() {
        if let index = currentIndex { save(documentID: documents[index].id) }
    }

    /// Save All menu command: like ⌘S for every unsaved document.
    func saveAll() {
        for document in documents where document.isDirty { save(documentID: document.id) }
    }

    /// Saves every unsaved document immediately, without formatting (before runs, on close/quit).
    func saveAllNow() {
        for index in documents.indices where documents[index].isDirty { save(at: index) }
    }

    private func save(documentID id: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let url = documents[index].url
        guard formatOnSave || organizeImportsOnSave, lspReady, Self.isJava(url), !isReadOnly(url) else {
            save(at: index)
            return
        }
        Task {
            if organizeImportsOnSave { await organizeImports(documentID: id, explicit: false) }
            if formatOnSave { await format(documentID: id, explicit: false) }
            if let index = documents.firstIndex(where: { $0.id == id }) { save(at: index) }
        }
    }

    /// Format Document command (jdtls' Eclipse formatter).
    func formatDocument() {
        guard let index = currentIndex, !isReadOnly(documents[index].url) else { return }
        let id = documents[index].id
        Task { await format(documentID: id, explicit: true) }
    }

    func organizeImportsInCurrentDocument() {
        guard let index = currentIndex, !isReadOnly(documents[index].url) else { return }
        let id = documents[index].id
        Task { await organizeImports(documentID: id, explicit: true) }
    }

    private func format(documentID id: String, explicit: Bool) async {
        guard let lsp, lspReady, let document = documents.first(where: { $0.id == id }) else {
            if explicit { flashStatus("jdtls is not ready yet") }
            return
        }
        let result: JSONValue
        do {
            result = try await lsp.request("textDocument/formatting", params: [
                "textDocument": ["uri": .string(document.uri)],
                "options": ["tabSize": 4, "insertSpaces": true],
            ])
        } catch {
            if explicit { flashStatus("Format failed: \(error.localizedDescription)") }
            return
        }
        // Skip if the user kept typing while the formatter ran.
        guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].text == document.text else { return }
        let edits = result.arrayValue?.compactMap(TextEdit.parse) ?? []
        let formatted = TextEdit.apply(edits, to: document.text)
        if formatted != document.text {
            setText(formatted, at: index)
        } else if explicit {
            flashStatus("Already formatted")
        }
    }

    private func organizeImports(documentID id: String, explicit: Bool) async {
        guard let lsp, lspReady, let document = documents.first(where: { $0.id == id }) else {
            if explicit { flashStatus("jdtls is not ready yet") }
            return
        }
        let end = LineIndex(document.text).position(of: (document.text as NSString).length)
        let result = try? await lsp.request("textDocument/codeAction", params: [
            "textDocument": ["uri": .string(document.uri)],
            "range": ["start": TextPosition(line: 0, character: 0).json, "end": end.json],
            "context": ["diagnostics": [], "only": ["source.organizeImports"]],
        ])
        let actions = result.map(CodeAction.parseList) ?? []
        guard let action = actions.first(where: { $0.kind?.hasPrefix("source.organizeImports") == true }) ?? actions.first else {
            if explicit { flashStatus("Imports already organized") }
            return
        }
        let before = documents.first { $0.id == id }?.text
        await perform(action)
        if explicit, before == documents.first(where: { $0.id == id })?.text { flashStatus("Imports already organized") }
    }

    @discardableResult
    private func save(at index: Int) -> Bool {
        let document = documents[index]
        guard !isReadOnly(document.url) else { return false }
        do {
            try document.text.write(to: document.url, atomically: true, encoding: .utf8)
            documents[index].isDirty = false
            if lspReady, Self.isJava(document.url) || Self.isBuildFile(document.url) {
                try? lsp?.notify("textDocument/didSave", params: ["textDocument": ["uri": .string(document.uri)]])
            }
            if Self.isBuildFile(document.url) {
                try? lsp?.notify("workspace/didChangeWatchedFiles", params: [
                    "changes": [["uri": .string(document.url.absoluteString), "type": 2]],
                ])
            }
            return true
        } catch {
            appendOutput("Save failed: \(error.localizedDescription)\n")
            bottomTab = .output
            return false
        }
    }

    /// For dirty documents about to be closed: asks Save / Don't Save / Cancel.
    /// Returns false if the user cancelled (or a save failed).
    func confirmDiscardOrSave(_ dirty: [OpenDocument]) -> Bool {
        let dirty = dirty.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Do you want to save the changes you made to \(dirty[0].name)?"
            : "Do you want to save the changes to \(dirty.count) files?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for document in dirty {
                guard let index = documents.firstIndex(where: { $0.id == document.id }), save(at: index) else { return false }
            }
            return true
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func reveal(_ problem: ProblemItem) {
        let url = URL(fileURLWithPath: problem.path)
        if currentFile.map(Self.key(for:)) != problem.path { openFile(url) }
        revealTarget = RevealTarget(position: problem.diagnostic.start)
    }

    // MARK: - Language features

    func completions(at offset: Int) async -> [CompletionItem] {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/completion", params: params)
        else { return [] }
        return CompletionItem.parseList(result)
    }

    func hover(at offset: Int) async -> String? {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/hover", params: params)
        else { return nil }
        return HoverContent.parse(result).map { String($0.prefix(4000)) }
    }

    func jumpToDefinition(at offset: Int) async {
        guard let url = currentFile, case let (lsp, params)? = positionRequest(at: offset) else { return }
        let origin = LineIndex(text).position(of: offset)
        let result = try? await lsp.request("textDocument/definition", params: params)
        guard let location = result.map(Location.parseAll)?.first else {
            flashStatus("No definition found")
            return
        }
        guard let target = await resolveLocationURL(location.uri) else {
            flashStatus("Can't open \(location.uri)")
            return
        }
        backStack.append(NavigationPoint(url: url, position: origin))
        if backStack.count > 100 { backStack.removeFirst() }
        navigate(to: target, position: location.start)
    }

    /// Maps an LSP URI to a local file: `file:` URIs directly; `jdt://` class files (JDK, JARs) are
    /// fetched with `java/classFileContents`, written to the cache and opened read-only.
    private func resolveLocationURL(_ uri: String) async -> URL? {
        if let url = URL(string: uri), url.isFileURL { return URL(fileURLWithPath: url.path) }
        guard ClassFileURI.isClassFile(uri), let lsp, let rootURL else { return nil }
        if let open = documents.first(where: { $0.lspURI == uri }) { return open.url }
        guard let source = try? await lsp.request("java/classFileContents", params: ["uri": .string(uri)]),
              let contents = source.stringValue, !contents.isEmpty else { return nil }
        let folder = JavaProject.cacheDirectory(for: rootURL)
            .appendingPathComponent("sources")
            .appendingPathComponent(ClassFileURI.packagePath(for: uri))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(ClassFileURI.fileName(for: uri))
        try? contents.write(to: file, atomically: true, encoding: .utf8)
        if !documents.contains(where: { $0.id == Self.key(for: file) }) {
            open(OpenDocument(url: file, text: contents, lspURI: uri))
        }
        return file
    }

    /// Re-fetches the current file's symbols, debounced while typing.
    private func scheduleOutlineRefresh(after delay: Duration) {
        outlineTask?.cancel()
        outlineTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            guard self.lspReady, self.isJavaFile, let document = self.currentDocument, let lsp = self.lsp else {
                self.outline = []
                return
            }
            let result = try? await lsp.request("textDocument/documentSymbol",
                                                params: ["textDocument": ["uri": .string(document.uri)]])
            guard !Task.isCancelled, self.currentDocumentID == document.id else { return }
            self.outline = result.map(OutlineSymbol.parse) ?? []
        }
    }

    func reveal(_ symbol: OutlineSymbol) {
        revealTarget = RevealTarget(position: symbol.position)
    }

    func signatureHelp(at offset: Int) async -> SignatureInfo? {
        guard case let (lsp, params)? = positionRequest(at: offset),
              let result = try? await lsp.request("textDocument/signatureHelp", params: params)
        else { return nil }
        return SignatureInfo.parse(result)
    }

    /// Fills the References panel with every use of the symbol at `offset`.
    func findReferences(at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(at: offset), case .object(var request) = params else { return }
        let ns = text as NSString
        referencesQuery = Identifier.wordRange(in: ns, at: offset).map(ns.substring(with:))
            ?? Identifier.wordRange(in: ns, at: offset - 1).map(ns.substring(with:)) ?? "symbol"
        request["context"] = ["includeDeclaration": true]
        let result = try? await lsp.request("textDocument/references", params: .object(request))
        let locations = result.map(Location.parseAll) ?? []
        var cache: [String: [Substring]] = [:]
        references = locations.compactMap { location -> ReferenceItem? in
            guard let uri = URL(string: location.uri), uri.isFileURL else { return nil }
            let url = URL(fileURLWithPath: uri.path)
            let key = Self.key(for: url)
            if cache[key] == nil {
                let source = documents.first { $0.id == key }?.text ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                cache[key] = source.split(separator: "\n", omittingEmptySubsequences: false)
            }
            let lines = cache[key] ?? []
            let line = lines.indices.contains(location.start.line) ? lines[location.start.line] : ""
            return ReferenceItem(url: url, position: location.start,
                                 lineText: line.trimmingCharacters(in: .whitespaces))
        }
        .sorted { (Self.key(for: $0.url), $0.position.line, $0.position.character)
                < (Self.key(for: $1.url), $1.position.line, $1.position.character) }
        bottomTab = .references
        if references.isEmpty { flashStatus("No references found") }
    }

    func openReference(_ item: ReferenceItem) {
        if let url = currentFile {
            backStack.append(NavigationPoint(url: url, position: LineIndex(text).position(of: caretOffset)))
            if backStack.count > 100 { backStack.removeFirst() }
        }
        navigate(to: item.url, position: item.position)
    }

    /// Prompts for a new name and applies the language server's rename across files.
    /// Changed files that aren't open are opened as unsaved tabs, so nothing is written without ⌘S.
    func renameSymbol(at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(at: offset), case .object(var request) = params else { return }
        let ns = text as NSString
        var oldName = Identifier.wordRange(in: ns, at: offset).map(ns.substring(with:))
            ?? Identifier.wordRange(in: ns, at: offset - 1).map(ns.substring(with:))
        if let prepared = try? await lsp.request("textDocument/prepareRename", params: params) {
            guard let range = PrepareRename.parse(prepared) else {
                flashStatus("Can't rename this symbol")
                return
            }
            oldName = range.placeholder ?? ns.substring(with: LineIndex(text).range(from: range.start, to: range.end))
        }
        guard let oldName, !oldName.isEmpty else {
            flashStatus("Put the caret on a symbol to rename it")
            return
        }
        guard let newName = Self.promptForName(oldName), newName != oldName else { return }
        request["newName"] = .string(newName)
        let result: JSONValue
        do {
            result = try await lsp.request("textDocument/rename", params: .object(request))
        } catch {
            flashStatus("Rename failed: \(error.localizedDescription)")
            return
        }
        let (occurrences, files) = applyWorkspaceEdit(result)
        flashStatus(files == 0 ? "Nothing to rename"
                    : "Renamed \(occurrences) occurrence\(occurrences == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s") — ⌥⌘S to save")
    }

    /// Applies a WorkspaceEdit to open buffers; files that aren't open are opened as unsaved tabs.
    /// Returns (edit count, file count).
    @discardableResult
    func applyWorkspaceEdit(_ edit: JSONValue) -> (Int, Int) {
        let changes = WorkspaceEdit.parse(edit)
        var occurrences = 0, files = 0
        for (uri, edits) in changes.sorted(by: { $0.key < $1.key }) {
            guard let parsed = URL(string: uri), parsed.isFileURL else { continue }
            let url = URL(fileURLWithPath: parsed.path)
            guard !isReadOnly(url) else { continue }
            let key = Self.key(for: url)
            if let index = documents.firstIndex(where: { $0.id == key }) {
                setText(TextEdit.apply(edits, to: documents[index].text), at: index)
            } else {
                guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }
                var document = OpenDocument(url: url, text: TextEdit.apply(edits, to: original))
                document.isDirty = true
                documents.append(document)
                sendDidOpen(document)
            }
            occurrences += edits.count
            files += 1
        }
        return (occurrences, files)
    }

    /// Quick fixes and refactorings for the caret / selection (⌥↩).
    func codeActions(at range: NSRange) async -> [CodeAction] {
        guard lspReady, isJavaFile, let document = currentDocument, let lsp else { return [] }
        let index = LineIndex(document.text)
        let start = index.position(of: range.location)
        let end = index.position(of: NSMaxRange(range))
        // Diagnostics touching the caret line(s), so jdtls offers their fixes.
        let related = currentDiagnostics.filter { $0.start.line <= end.line && $0.end.line >= start.line }
        let diagnosticsJSON: [JSONValue] = related.map { d in
            d.raw ?? [
                "range": ["start": d.start.json, "end": d.end.json],
                "severity": .int(d.severity.rawValue),
                "message": .string(d.message),
            ]
        }
        let result = try? await lsp.request("textDocument/codeAction", params: [
            "textDocument": ["uri": .string(document.uri)],
            "range": ["start": start.json, "end": end.json],
            "context": ["diagnostics": .array(diagnosticsJSON), "triggerKind": 1],
        ])
        return result.map(CodeAction.parseList) ?? []
    }

    func requestQuickFixes() {
        quickFixRequest = UUID()
    }

    /// Applies a code action: resolve if needed, apply its edit, then run its command.
    func perform(_ action: CodeAction) async {
        guard let lsp else { return }
        var action = action
        if action.needsResolve, let resolved = try? await lsp.request("codeAction/resolve", params: action.raw),
           let parsed = CodeAction.parse(resolved) {
            action = parsed
        }
        if let edit = action.edit { applyWorkspaceEdit(edit) }
        if let command = action.command, let name = command["command"]?.stringValue {
            do {
                _ = try await lsp.request("workspace/executeCommand", params: [
                    "command": .string(name),
                    "arguments": command["arguments"] ?? .array([]),
                ])
            } catch {
                flashStatus("\(action.title) failed: \(error.localizedDescription)")
            }
        }
    }

    private static func promptForName(_ oldName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename '\(oldName)'"
        alert.informativeText = "All references in the project will be updated. Changed files stay unsaved until you save them."
        let field = NSTextField(string: oldName)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if Identifier.isValidJavaName(name) { return name }
            alert.informativeText = "'\(name)' is not a valid Java identifier."
        }
        return nil
    }

    func goBack() {
        guard let point = backStack.popLast() else { return }
        navigate(to: point.url, position: point.position)
    }

    private func navigate(to url: URL, position: TextPosition) {
        if currentFile.map(Self.key(for:)) != Self.key(for: url) { openFile(url) }
        guard currentFile.map(Self.key(for:)) == Self.key(for: url) else { return }
        revealTarget = RevealTarget(position: position)
    }

    private func positionRequest(at offset: Int) -> (LSPClient, JSONValue)? {
        guard lspReady, isJavaFile, let document = currentDocument, let lsp else { return nil }
        let position = LineIndex(document.text).position(of: offset)
        return (lsp, ["textDocument": ["uri": .string(document.uri)], "position": position.json])
    }

    func flashStatus(_ message: String) {
        let previous = lspStatus
        lspStatus = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if lspStatus == message { lspStatus = previous }
        }
    }

    // MARK: - Language server

    func restartLanguageServer() async {
        guard let rootURL else { return }
        await stopLanguageServer()
        await startLanguageServer(root: rootURL)
    }

    /// Wipes jdtls' index for this project (fixes a confused classpath) and restarts it.
    func cleanLanguageServerWorkspace() async {
        guard let rootURL else { return }
        await stopLanguageServer()
        try? FileManager.default.removeItem(at: JavaProject.cacheDirectory(for: rootURL).appendingPathComponent("jdtls-data"))
        await startLanguageServer(root: rootURL)
    }

    private func startLanguageServer(root: URL) async {
        let name = LanguageServerSpec.name
        guard let executable = LanguageServerSpec.locate() else {
            lspStatus = "jdtls not found — \(LanguageServerSpec.installHint)"
            return
        }
        let jdk = self.jdk
        let debugJar = JavaDebugLocator.installedJar
        let client = LSPClient()
        client.configurationProvider = { items in
            LanguageServerSpec.configuration(items: items, jdk: jdk)
        }
        client.applyEditHandler = { [weak self] edit in
            await MainActor.run {
                guard let self else { return false }
                self.applyWorkspaceEdit(edit)
                return true
            }
        }
        client.onNotification = { method, params in
            Task { @MainActor in self.handleNotification(client, method: method, params: params) }
        }
        client.onExit = { status in
            Task { @MainActor in
                guard self.lsp === client else { return }
                self.lsp = nil
                self.lspReady = false
                self.lspStatus = "\(name) exited (status \(status))"
            }
        }

        do {
            try FileManager.default.createDirectory(at: JavaProject.cacheDirectory(for: root), withIntermediateDirectories: true)
            try client.start(executable: executable, arguments: LanguageServerSpec.arguments(root: root),
                             environment: LanguageServerSpec.environment(base: ProcessInfo.processInfo.environment),
                             currentDirectory: root)
            lsp = client
            lspStatus = "\(name): starting…"
            lspServiceReady = false
            _ = try await client.request("initialize", params: Self.initializeParams(root: root, jdk: jdk, bundles: debugJar.map { [$0] } ?? []))
            lspHasDebugBundle = debugJar != nil
            guard lsp === client else { return }  // folder changed while initializing
            try client.notify("initialized", params: [:])
            try client.notify("workspace/didChangeConfiguration", params: ["settings": LanguageServerSpec.settings(jdk: jdk)])
            lspReady = true
            if lspStatus == "\(name): starting…" { lspStatus = "\(name): importing project…" }
            scheduleOutlineRefresh(after: .zero)
            documents.forEach(sendDidOpen)
        } catch {
            if lsp === client { lsp = nil }
            lspStatus = "\(name) failed: \(error.localizedDescription)"
        }
    }

    private func stopLanguageServer() async {
        guard let client = lsp else { return }
        lsp = nil
        lspReady = false
        client.onNotification = nil
        client.onExit = nil
        client.applyEditHandler = nil
        lspStatus = "\(LanguageServerSpec.name): stopped"
        await client.shutdown()
    }

    private func handleNotification(_ client: LSPClient, method: String, params: JSONValue) {
        guard lsp === client else { return }
        switch method {
        case "textDocument/publishDiagnostics":
            guard let published = Diagnostic.parsePublish(params) else { return }
            let key: String
            if let url = URL(string: published.uri), url.isFileURL {
                key = Self.key(for: url)
            } else if let doc = documents.first(where: { $0.lspURI == published.uri }) {
                key = doc.id
            } else {
                return
            }
            let shown = published.diagnostics.filter { $0.severity != .hint }
            if shown.isEmpty {
                diagnostics.removeValue(forKey: key)
            } else {
                diagnostics[key] = shown
            }
        case "language/status":
            // jdtls: {type: "Starting" | "Started" | "ServiceReady" | "Error" | "ProjectStatus", message}
            let type = params["type"]?.stringValue ?? ""
            let message = params["message"]?.stringValue ?? ""
            switch type {
            case "ServiceReady":
                lspServiceReady = true
                lspStatus = "jdtls: ready"
                scheduleOutlineRefresh(after: .zero)
            case "Started":
                if !lspStatus.hasSuffix("ready") { lspStatus = "jdtls: ready" }
            case "Error":
                lspStatus = "jdtls: \(message)"
            case "ProjectStatus":
                if message != "OK" { lspStatus = "jdtls: project \(message.lowercased())" }
            case "Starting":
                if !message.isEmpty { lspStatus = "jdtls: \(String(message.prefix(80)))" }
            default:
                break
            }
        case "window/showMessage":
            if let message = params["message"]?.stringValue {
                let type = params["type"]?.intValue ?? 3
                if type <= 2 { lspStatus = "jdtls: \(String(message.prefix(120)))" }
            }
        default:
            break
        }
    }

    private func sendDidOpen(_ document: OpenDocument) {
        guard lspReady, Self.isJava(document.url) else { return }
        try? lsp?.notify("textDocument/didOpen", params: [
            "textDocument": [
                "uri": .string(document.uri),
                "languageId": "java",
                "version": .int(document.version),
                "text": .string(document.text),
            ],
        ])
    }

    private func sendDidClose(_ document: OpenDocument) {
        guard lspReady, Self.isJava(document.url) else { return }
        try? lsp?.notify("textDocument/didClose", params: ["textDocument": ["uri": .string(document.uri)]])
    }

    private static func initializeParams(root: URL, jdk: JDK?, bundles: [URL]) -> JSONValue {
        let textDocument: JSONValue = [
            "synchronization": ["didSave": true, "dynamicRegistration": false],
            "publishDiagnostics": ["relatedInformation": false],
            "completion": [
                "completionItem": ["snippetSupport": false, "documentationFormat": ["markdown", "plaintext"]],
            ],
            "hover": ["contentFormat": ["markdown", "plaintext"]],
            "definition": ["linkSupport": false],
            "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
            "references": [:],
            "formatting": ["dynamicRegistration": false],
            "rename": ["prepareSupport": true],
            "codeAction": [
                "codeActionLiteralSupport": [
                    "codeActionKind": ["valueSet": ["", "quickfix", "refactor", "refactor.extract", "refactor.inline",
                                                    "refactor.rewrite", "source", "source.organizeImports"]],
                ],
                "resolveSupport": ["properties": ["edit"]],
                "dataSupport": true,
            ],
            "signatureHelp": [
                "signatureInformation": [
                    "documentationFormat": ["markdown", "plaintext"],
                    "parameterInformation": ["labelOffsetSupport": true],
                    "activeParameterSupport": true,
                ],
            ],
        ]
        let workspace: JSONValue = ["configuration": true, "workspaceFolders": true, "applyEdit": true,
                                    "executeCommand": ["dynamicRegistration": false],
                                    "workspaceEdit": ["documentChanges": true]]
        return [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "JavaIDE", "version": "0.1.0"],
            "rootUri": .string(root.absoluteString),
            "workspaceFolders": [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]],
            "initializationOptions": LanguageServerSpec.initializationOptions(jdk: jdk, bundles: bundles),
            "capabilities": [
                "textDocument": textDocument,
                "workspace": workspace,
                "general": ["positionEncodings": ["utf-16"]],
            ],
        ]
    }

    // MARK: - Run / test / build

    func run(_ action: RunAction) {
        guard let rootURL, !isRunning else { return }
        guard let jdk else {
            output = "No JDK found. Install one (brew install openjdk) or choose a JDK from the status bar.\n"
            bottomTab = .output
            return
        }
        saveAllNow()
        let command: RunCommand?
        switch action {
        case .run:
            guard let target = mainClassTarget() else {
                output = "Nothing to run: open a class with a main method.\n"
                bottomTab = .output
                return
            }
            command = RunCommand.run(mainClass: target.className, file: target.file, buildSystem: buildSystem,
                                     root: rootURL, jdk: jdk, sources: Self.allJavaFiles(in: fileTree))
        case .test:
            let testClass = currentFile.flatMap { file -> String? in
                guard let doc = currentDocument, Self.isJava(file), JavaProject.isTestSource(file: file, source: doc.text) else { return nil }
                return JavaProject.qualifiedClassName(file: file, source: doc.text)
            }
            command = RunCommand.test(className: testClass, buildSystem: buildSystem, root: rootURL)
        case .build:
            command = RunCommand.build(buildSystem: buildSystem, root: rootURL, jdk: jdk,
                                       sources: Self.allJavaFiles(in: fileTree))
        }
        guard let command else {
            output = buildSystem == .plain && action == .test
                ? "Running tests needs a Maven (pom.xml) or Gradle (build.gradle) project.\n"
                : "\(buildSystem.displayName) not found on PATH (brew install \(buildSystem == .maven ? "maven" : "gradle")).\n"
            bottomTab = .output
            return
        }
        start(command)
    }

    /// The current file if it declares `main`, else the first project file that does.
    private func mainClassTarget() -> (file: URL, className: String)? {
        if let doc = currentDocument, Self.isJava(doc.url), !isReadOnly(doc.url), JavaProject.hasMainMethod(doc.text) {
            return (doc.url, JavaProject.qualifiedClassName(file: doc.url, source: doc.text))
        }
        guard let file = Self.firstMainFile(in: fileTree),
              let source = documents.first(where: { $0.id == Self.key(for: file) })?.text
                ?? (try? String(contentsOf: file, encoding: .utf8)) else { return nil }
        return (file, JavaProject.qualifiedClassName(file: file, source: source))
    }

    private func start(_ command: RunCommand) {
        guard let rootURL, !isRunning else { return }
        output = "$ \(command.display)\n"
        bottomTab = .output
        isRunning = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.shell]
        process.currentDirectoryURL = rootURL
        var environment = ToolLocator.environment(jdk: jdk)
        environment["MAVEN_OPTS"] = (environment["MAVEN_OPTS"].map { $0 + " " } ?? "") + "-Djansi.passthrough=false"
        process.environment = environment
        let pipe = Pipe(), input = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = input
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.appendOutput(chunk) }
        }
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                // Let any final output chunks land first.
                try? await Task.sleep(for: .milliseconds(50))
                self.isRunning = false
                self.runProcess = nil
                try? self.runInput?.close()
                self.runInput = nil
                self.appendOutput("\n[process exited with status \(status)]\n")
            }
        }
        do {
            try process.run()
            runProcess = process
            runInput = input.fileHandleForWriting
        } catch {
            isRunning = false
            appendOutput("Failed to start: \(error.localizedDescription)\n")
        }
    }

    /// Sends a line to the running program's stdin (for `Scanner` / `readLine`), echoing it in the output.
    func sendInput(_ line: String) {
        guard let runInput else { return }
        appendOutput(line + "\n")
        try? runInput.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Closes the program's stdin (Ctrl-D).
    func sendEOF() {
        try? runInput?.close()
        runInput = nil
    }

    func stopRun() {
        if isDebugging, runProcess == nil {
            stopDebugging()
            return
        }
        guard let runProcess else { return }
        // Commands `exec` the final tool, so SIGINT reaches the JVM / Maven / Gradle directly.
        runProcess.interrupt()
        Task {
            try? await Task.sleep(for: .seconds(2))
            if runProcess.isRunning { runProcess.terminate() }
        }
    }

    private func appendOutput(_ s: String) {
        output += s
        if output.utf16.count > 1_000_000 { output = String(output.suffix(800_000)) }
    }

    // MARK: - Debugging (java-debug inside jdtls)

    var isDebugging: Bool { debugSession?.isActive ?? false }

    var currentBreakpoints: Set<Int> { Set((breakpoints[currentDocumentID] ?? [:]).keys) }

    var currentConditionalBreakpoints: Set<Int> {
        Set((breakpoints[currentDocumentID] ?? [:]).filter { !$0.value.isEmpty }.keys)
    }

    var currentExecutionLine: Int? {
        guard let executionLocation, executionLocation.key == currentDocumentID else { return nil }
        return executionLocation.line
    }

    private static func sourceBreakpoints(_ lines: [Int: String]) -> [SourceBreakpoint] {
        lines.map { SourceBreakpoint(line: $0.key + 1, condition: $0.value.isEmpty ? nil : $0.value) }
    }

    private func updateBreakpoints(_ lines: [Int: String], for key: String) {
        breakpoints[key] = lines.isEmpty ? nil : lines
        debugSession?.setBreakpoints(path: key, Self.sourceBreakpoints(lines))
    }

    func toggleBreakpointAtCaret() {
        toggleBreakpoint(line: LineIndex(text).position(of: caretOffset).line)
    }

    func toggleBreakpoint(line: Int) {
        guard let currentFile, Self.isJava(currentFile) else { return }
        let key = currentDocumentID
        var lines = breakpoints[key] ?? [:]
        if lines[line] != nil { lines.removeValue(forKey: line) } else { lines[line] = "" }
        updateBreakpoints(lines, for: key)
    }

    /// Asks for a Java boolean expression; the breakpoint only pauses when it is true.
    func editBreakpointCondition(line: Int) {
        let key = currentDocumentID
        let alert = NSAlert()
        alert.messageText = "Breakpoint condition (line \(line + 1))"
        alert.informativeText = "Pause only when this Java expression is true. Leave empty to always pause."
        let field = NSTextField(string: breakpoints[key]?[line] ?? "")
        field.placeholderString = "e.g. i == 3"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var lines = breakpoints[key] ?? [:]
        lines[line] = field.stringValue.trimmingCharacters(in: .whitespaces)
        updateBreakpoints(lines, for: key)
    }

    func removeBreakpoint(line: Int) {
        var lines = breakpoints[currentDocumentID] ?? [:]
        lines.removeValue(forKey: line)
        updateBreakpoints(lines, for: currentDocumentID)
    }

    func clearAllBreakpoints() {
        for key in breakpoints.keys { debugSession?.setBreakpoints(path: key, []) }
        breakpoints = [:]
    }

    /// Debugs the current class (or the project's first main class) under java-debug.
    func startDebugging() async {
        guard let rootURL, !isDebugging, !isRunning else { return }
        guard let jdk else {
            flashStatus("No JDK found — choose one in the status bar")
            return
        }
        saveAllNow()
        if JavaDebugLocator.installedJar == nil {
            guard await installJavaDebug() else { return }
        }
        if !lspHasDebugBundle || lsp == nil {
            lspStatus = "jdtls: restarting with the debugger…"
            await restartLanguageServer()
        }
        guard let lsp, await waitForServiceReady() else {
            flashStatus("jdtls is not ready — try again when the status bar says ready")
            return
        }
        bottomTab = .debug
        do {
            // 1. Which main class, in which jdtls project.
            let mains = try await lsp.request("workspace/executeCommand", params: [
                "command": "vscode.java.resolveMainClass", "arguments": [.string(rootURL.absoluteString)],
            ]).arrayValue ?? []
            let currentKey = currentFile.map(Self.key(for:))
            let entry = mains.first { m in m["filePath"]?.stringValue.map { Self.key(for: URL(fileURLWithPath: $0)) } == currentKey }
                ?? mains.first
            guard let entry, let mainClass = entry["mainClass"]?.stringValue else {
                flashStatus("No main class found to debug")
                return
            }
            let projectName = entry["projectName"]?.stringValue ?? ""
            // 2. Its class path (includes Maven/Gradle dependencies).
            let paths = try await lsp.request("workspace/executeCommand", params: [
                "command": "vscode.java.resolveClasspath", "arguments": [.string(mainClass), .string(projectName)],
            ])
            // 3. A debug adapter listening on a local port.
            let portResult = try await lsp.request("workspace/executeCommand", params: ["command": "vscode.java.startDebugSession"])
            guard let port = portResult.intValue else {
                flashStatus("java-debug did not start (is the bundle loaded?)")
                return
            }
            let launch: JSONValue = [
                "type": "java", "request": "launch", "name": .string(mainClass),
                "mainClass": .string(mainClass), "projectName": .string(projectName),
                "modulePaths": paths[0] ?? .array([]), "classPaths": paths[1] ?? .array([]),
                "cwd": .string(rootURL.path), "console": "integratedTerminal",
                "javaExec": .string(jdk.java.path), "args": "", "vmArgs": "", "stopOnEntry": false,
                "encoding": "UTF-8",
            ]
            startSession(port: port, launch: launch, programName: mainClass, jdk: jdk)
        } catch {
            flashStatus("Debug failed: \(error.localizedDescription)")
        }
    }

    private func startSession(port: Int, launch: JSONValue, programName: String, jdk: JDK) {
        let session = DebugSession(breakpoints: breakpoints.mapValues(Self.sourceBreakpoints), programName: programName)
        session.onLocation = { [weak self, weak session] location in
            guard let self, self.debugSession === session else { return }
            guard let (path, line) = location else {
                self.executionLocation = nil
                return
            }
            let url = URL(fileURLWithPath: path)
            self.executionLocation = ExecutionLocation(key: Self.key(for: url), line: max(line - 1, 0))
            self.navigate(to: url, position: TextPosition(line: max(line - 1, 0), character: 0))
            self.bottomTab = .debug
        }
        session.onEnd = { [weak self, weak session] in
            guard let self, self.debugSession === session else { return }
            self.executionLocation = nil
        }
        debugSession = session
        bottomTab = .debug
        session.start(port: port, launchArguments: launch, environment: ToolLocator.environment(jdk: jdk))
    }

    func stopDebugging() {
        debugSession?.stop()
    }

    private func waitForServiceReady(timeout: Duration = .seconds(120)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !lspServiceReady, lsp != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return lspServiceReady && lsp != nil
    }

    /// Asks, then downloads Microsoft's java-debug plugin from Maven Central (checksum-verified).
    private func installJavaDebug() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download the Java debugger?"
        alert.informativeText = "Debugging uses Microsoft's java-debug plugin for jdtls (\(JavaDebugLocator.jarName), ~3 MB). "
            + "JavaIDE downloads it from Maven Central into \(JavaDebugLocator.supportDirectory.path) and verifies its checksum."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        lspStatus = "Downloading java-debug…"
        do {
            _ = try await JavaDebugLocator.install()
            lspStatus = "java-debug installed"
            return true
        } catch {
            flashStatus("java-debug download failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - REPL (jshell)

    func startREPL() {
        guard repl == nil else { return }
        guard let jdk, FileManager.default.isExecutableFile(atPath: jdk.jshell.path) else {
            replOutput += "jshell not found. Choose a JDK 9+ first.\n"
            return
        }
        let session = JShellREPL()
        session.onOutput = { chunk in Task { @MainActor in self.appendREPL(chunk) } }
        session.onExit = { status in
            Task { @MainActor in
                guard self.repl === session else { return }
                self.repl = nil
                self.isREPLRunning = false
                self.appendREPL("\n[jshell exited with status \(status)]\n")
            }
        }
        let classPath = rootURL.map { buildSystem.classOutputDirectories(root: $0) } ?? []
        do {
            try session.start(jshell: jdk.jshell, arguments: JShellREPL.arguments(classPath: classPath),
                              environment: ToolLocator.environment(jdk: jdk), currentDirectory: rootURL)
            repl = session
            isREPLRunning = true
            let onPath = classPath.filter { FileManager.default.fileExists(atPath: $0.path) }
            appendREPL("// jshell — \(jdk.label)"
                       + (onPath.isEmpty ? "" : "\n// class path: \(onPath.map(relativePath).joined(separator: ":"))") + "\n")
        } catch {
            appendREPL("Failed to start jshell: \(error.localizedDescription)\n")
        }
    }

    /// Sends one line typed in the REPL panel (echoed, since a piped jshell doesn't echo input).
    func sendREPLLine(_ line: String) {
        if repl == nil { startREPL() }
        appendREPL(line + "\n")
        repl?.send(line)
    }

    /// Sends the editor selection, or the caret's line, to jshell.
    func sendSelectionToREPL() {
        let ns = text as NSString
        guard ns.length > 0 else { return }
        let selection = NSRange(location: min(selectedRange.location, ns.length),
                                length: min(selectedRange.length, ns.length - min(selectedRange.location, ns.length)))
        let range = selection.length > 0 ? selection : ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let code = JShellREPL.prepareForSending(ns.substring(with: range))
        guard !code.isEmpty else {
            flashStatus("Nothing to send — select code or put the caret on a line")
            return
        }
        bottomTab = .repl
        if repl == nil { startREPL() }
        appendREPL(code)
        repl?.send(code)
    }

    func interruptREPL() { repl?.interrupt() }

    func restartREPL() {
        stopREPL()
        appendREPL("\n// Restarting…\n")
        startREPL()
    }

    func clearREPL() { replOutput = "" }

    private func stopREPL() {
        guard let session = repl else { return }
        repl = nil
        isREPLRunning = false
        session.onExit = nil
        session.stop()
    }

    private func appendREPL(_ s: String) {
        replOutput += s
        if replOutput.utf16.count > 400_000 { replOutput = String(replOutput.suffix(300_000)) }
    }

    // MARK: - Helpers

    nonisolated static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    nonisolated static func isJava(_ url: URL) -> Bool {
        url.pathExtension == "java"
    }

    nonisolated static func isBuildFile(_ url: URL) -> Bool {
        ["pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"].contains(url.lastPathComponent)
    }

    func relativePath(_ url: URL) -> String {
        guard let root = rootURL?.path else { return url.path }
        if url.path == root { return "" }
        guard url.path.hasPrefix(root + "/") else { return url.path }
        return String(url.path.dropFirst(root.count + 1))
    }

    static func allJavaFiles(in nodes: [FileNode]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if node.isDirectory { return allJavaFiles(in: node.children ?? []) }
            return isJava(node.url) ? [node.url] : []
        }
    }

    /// First file (depth-first, main sources before tests) that declares a `main` method.
    private static func firstMainFile(in nodes: [FileNode]) -> URL? {
        allJavaFiles(in: nodes)
            .filter { !$0.path.contains("/src/test/") }
            .first { url in
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return JavaProject.hasMainMethod(source)
            }
    }

    private static func firstJavaFile(in nodes: [FileNode]) -> URL? {
        allJavaFiles(in: nodes).first
    }
}
