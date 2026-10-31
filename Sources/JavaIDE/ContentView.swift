import JavaIDECore
import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            if workspace.rootURL == nil {
                WelcomeView()
            } else {
                EditorArea()
            }
        }
        .navigationTitle(workspace.rootURL?.lastPathComponent ?? "JavaIDE")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.run(.build) } label: {
                    Label("Build", systemImage: "hammer")
                }
                .help("Compile with \(workspace.buildSystem.displayName) (⌘B)")
                .disabled(workspace.isRunning(key: "build"))
                Button { workspace.run(.test) } label: {
                    Label("Test", systemImage: "checkmark.diamond")
                }
                .help("Run tests — the current test class, or all (⌘U)")
                .disabled(workspace.isRunning(key: "test"))
                RunTargetMenu()
                Button { workspace.run(.run) } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .help("Run \(workspace.runTargetLabel == "Current File" ? "the current class's main method" : workspace.runTargetLabel) (⌘R); runs again if it is already running")
                Button { Task { await workspace.startDebugging() } } label: {
                    Label("Debug", systemImage: "ladybug")
                }
                .help("Debug the Run target (⇧⌘D)")
                .disabled(workspace.isDebugging)
                Button { workspace.stopRun() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop the selected program (⌘.)")
                .disabled(!workspace.isRunning && !workspace.isDebugging)
            }
        }
        .sheet(item: $workspace.editingRunTarget) { target in
            RunConfigurationSheet(target: target, configuration: workspace.runConfiguration(for: target))
        }
        .task { await workspace.handleLaunchArguments() }
    }
}

/// Toolbar picker for what Run / Debug start, plus run configuration and Run All.
struct RunTargetMenu: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Menu {
            Button(check(nil) + "Current File") { workspace.selectedRunTargetID = nil }
            if !workspace.runTargets.isEmpty { Divider() }
            ForEach(workspace.runTargets) { target in
                Button {
                    workspace.selectedRunTargetID = target.id
                } label: {
                    Label(check(target.id) + target.displayName, systemImage: target.isSpringBoot ? "leaf" : "play")
                }
            }
            Divider()
            Button("Edit Run Configuration…") { workspace.editRunConfiguration() }
            if workspace.springBootTargets.count > 1 {
                Button("Run All Spring Boot Apps (\(workspace.springBootTargets.count))") { workspace.runAllSpringBootApps() }
            }
            if workspace.runSessions.filter(\.isRunning).count > 1 {
                Button("Stop All") { workspace.stopAll() }
            }
        } label: {
            Label(workspace.runTargetLabel, systemImage: workspace.currentRunTarget?.isSpringBoot == true ? "leaf" : "scope")
                .labelStyle(.titleAndIcon)
        }
        .help("Run target: what Run and Debug start")
        .fixedSize()
    }

    private func check(_ id: String?) -> String { workspace.selectedRunTargetID == id ? "✓ " : "" }
}

/// Spring profiles, program arguments, JVM options and environment variables for one Run target.
struct RunConfigurationSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    let target: RunTarget
    @State var configuration: RunConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Configuration").font(.headline)
            Text(target.mainClass + (target.module.isRoot ? "" : " — module \(target.module.relativePath)"))
                .font(.callout).foregroundStyle(.secondary)
            Form {
                if target.isSpringBoot {
                    TextField("Active profiles", text: $configuration.profiles, prompt: Text("dev, local"))
                }
                TextField("Program arguments", text: $configuration.programArguments,
                          prompt: Text(target.isSpringBoot ? "--server.port=8081" : "arg1 \"arg two\""))
                TextField("VM options", text: $configuration.vmOptions, prompt: Text("-Xmx512m -Dfoo=bar"))
                LabeledContent("Environment") {
                    TextEditor(text: $configuration.environment)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                        .overlay(alignment: .topLeading) {
                            if configuration.environment.isEmpty {
                                Text("NAME=value, one per line").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                }
            }
            if target.isSpringBoot {
                Text("Profiles are passed as SPRING_PROFILES_ACTIVE. Used by Run and Debug.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    workspace.setRunConfiguration(configuration, for: target)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                Button("Save & Run") {
                    workspace.setRunConfiguration(configuration, for: target)
                    dismiss()
                    workspace.run(target)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct WelcomeView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("JavaIDE").font(.largeTitle.bold())
            Text("Open a Java project folder — Maven, Gradle, or plain sources.")
                .foregroundStyle(.secondary)
            Button("Open Folder…") { workspace.presentOpenPanel() }
                .keyboardShortcut("o")
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum SidebarMode: String {
    case files, outline
}

struct Sidebar: View {
    @AppStorage("sidebarMode") private var mode: SidebarMode = .files

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $mode) {
                Image(systemName: "folder").help("Files").tag(SidebarMode.files)
                Image(systemName: "list.bullet.indent").help("Outline").tag(SidebarMode.outline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            switch mode {
            case .files: FileTreeView()
            case .outline: OutlineView()
            }
        }
    }
}

struct OutlineView: View {
    @Environment(Workspace.self) private var workspace
    @State private var selection: UUID?

    var body: some View {
        if workspace.outline.isEmpty {
            Text(workspace.isJavaFile ? "No symbols" : "Open a Java file")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(workspace.outline, children: \.children, selection: $selection) { symbol in
                HStack(spacing: 6) {
                    Image(systemName: Self.style(symbol.kind).symbol)
                        .foregroundStyle(Self.style(symbol.kind).color)
                    Text(symbol.name).lineLimit(1)
                    if let detail = symbol.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .tag(symbol.id)
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, id in
                if let id, let symbol = Self.find(id, in: workspace.outline) { workspace.reveal(symbol) }
            }
        }
    }

    private static func find(_ id: UUID, in symbols: [OutlineSymbol]) -> OutlineSymbol? {
        for symbol in symbols {
            if symbol.id == id { return symbol }
            if let hit = find(id, in: symbol.children ?? []) { return hit }
        }
        return nil
    }

    private static func style(_ kind: OutlineSymbol.Kind) -> (symbol: String, color: Color) {
        switch kind {
        case .classType: ("c.square.fill", .green)
        case .method, .constructor: ("m.square.fill", .purple)
        case .function: ("f.square.fill", .purple)
        case .property, .field: ("p.square.fill", .blue)
        case .variable: ("v.square.fill", .blue)
        case .constant: ("k.square.fill", .orange)
        case .module: ("shippingbox.fill", .brown)
        case .other: ("circle.fill", .gray)
        }
    }
}

struct FileTreeView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let selection = Binding<URL?>(
            get: { workspace.currentFile },
            set: { if let url = $0 { workspace.openFile(url) } })

        List(workspace.fileTree, children: \.children, selection: selection) { node in
            Label(node.name, systemImage: Self.icon(for: node))
                .lineLimit(1)
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("Reload") { workspace.reloadTree() }
        }
    }

    private static func icon(for node: FileNode) -> String {
        if node.isDirectory { return "folder" }
        switch node.url.pathExtension {
        case "py", "pyi", "pyw": return "doc.text"
        case "toml", "cfg", "ini", "lock": return "shippingbox"
        case "ipynb": return "book"
        case "md": return "doc.richtext"
        case "java": return "cup.and.saucer"
        case "properties", "yml", "yaml": return "gearshape"
        case "xml", "gradle", "kts": return "shippingbox"
        default: return "doc"
        }
    }
}

struct EditorArea: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                if !workspace.documents.isEmpty {
                    TabBar()
                    Divider()
                }
                EditorHeader()
                Divider()
                if workspace.currentFile != nil {
                    CodeEditorView(
                        documentID: workspace.currentDocumentID,
                        openDocumentIDs: Set(workspace.documents.map(\.id)),
                        text: workspace.text,
                        highlightCode: workspace.isJavaFile,
                        language: workspace.currentFile.map(SyntaxLanguage.forFile) ?? .none,
                        isEditable: !workspace.isReadOnly,
                        diagnostics: workspace.currentDiagnostics,
                        breakpointLines: workspace.currentBreakpoints,
                        conditionalBreakpointLines: workspace.currentConditionalBreakpoints,
                        executionLine: workspace.currentExecutionLine,
                        reveal: workspace.revealTarget,
                        quickFixRequest: workspace.quickFixRequest,
                        services: EditorServices(
                            completions: { await workspace.completions(at: $0) },
                            hover: { await workspace.hover(at: $0) },
                            signatureHelp: { await workspace.signatureHelp(at: $0) },
                            definition: { offset in Task { await workspace.jumpToDefinition(at: offset) } },
                            references: { offset in Task { await workspace.findReferences(at: offset) } },
                            rename: { offset in Task { await workspace.renameSymbol(at: offset) } },
                            codeActions: { await workspace.codeActions(at: $0) },
                            performCodeAction: { action in Task { await workspace.perform(action) } },
                            toggleBreakpoint: { workspace.toggleBreakpoint(line: $0) },
                            editBreakpointCondition: { workspace.editBreakpointCondition(line: $0) },
                            removeBreakpoint: { workspace.removeBreakpoint(line: $0) },
                            caretMoved: {
                                workspace.caretOffset = $0.location
                                workspace.selectedRange = $0
                            }),
                        onChange: { workspace.updateText($0) })
                } else {
                    Text("Select a file")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 200)

            BottomPanel()
                .frame(minHeight: 100, idealHeight: 180)
        }
    }
}

struct TabBar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(workspace.documents) { document in
                        TabItem(document: document, isSelected: document.id == workspace.currentDocumentID)
                            .id(document.id)
                        Divider().frame(height: 18)
                    }
                }
            }
            .onChange(of: workspace.currentDocumentID) { _, id in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
        .frame(height: 30)
        .background(.bar)
    }
}

struct TabItem: View {
    @Environment(Workspace.self) private var workspace
    let document: OpenDocument
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: workspace.isReadOnly(document.url) ? "lock.doc" : "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(document.name)
                .font(.callout)
                .fontWeight(isSelected ? .medium : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
            ZStack {
                if isHovering || !document.isDirty {
                    Button { workspace.close(document) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .opacity(isHovering || isSelected ? 1 : 0)
                    .help("Close Tab (⌘W)")
                } else {
                    Circle().fill(.secondary).frame(width: 7, height: 7).help("Unsaved changes")
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(isSelected ? Color(nsColor: .textBackgroundColor) : .clear)
        .overlay(alignment: .top) {
            if isSelected { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectTab(document) }
        .onHover { isHovering = $0 }
        .help(workspace.relativePath(document.url))
        .contextMenu {
            Button("Close") { workspace.close(document) }
            Button("Close Others") { workspace.closeOthers(document) }
                .disabled(workspace.documents.count < 2)
            Button("Close All") { workspace.closeAll() }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
        }
    }
}

struct EditorHeader: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 6) {
            Button { workspace.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(!workspace.canGoBack)
                .help("Go Back (⌃⌘←)")
            if let file = workspace.currentFile {
                Text(relativePath(file)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                if workspace.isReadOnly {
                    Text("Read Only")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    private func relativePath(_ url: URL) -> String { workspace.relativePath(url) }
}

struct BottomPanel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $workspace.bottomTab) {
                    Text("Problems (\(workspace.allProblems.count))").tag(BottomTab.problems)
                    Text("Output").tag(BottomTab.output)
                    Text("JShell").tag(BottomTab.repl)
                    Text(workspace.isDebugging ? "Debug ●" : "Debug").tag(BottomTab.debug)
                    if !workspace.references.isEmpty || workspace.bottomTab == .references {
                        Text("References (\(workspace.references.count))").tag(BottomTab.references)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if workspace.isRunning { ProgressView().controlSize(.small) }
                Text(workspace.buildSystem.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Build system (detected from pom.xml / build.gradle)")
                Menu {
                    ForEach(JDK.installed(), id: \.home) { jdk in
                        Button(jdk.label + (jdk.home == workspace.jdk?.home ? " ✓" : "")) { workspace.chooseJDK(jdk) }
                    }
                    Divider()
                    Button("Other JDK…") { workspace.presentJDKPanel() }
                } label: {
                    Label(workspace.jdkLabel, systemImage: "cup.and.saucer")
                        .font(.caption)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(workspace.jdk?.home.path ?? "Choose a JDK")
                Divider().frame(height: 12)
                Text(workspace.lspStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            switch workspace.bottomTab {
            case .problems: ProblemsList()
            case .output: OutputView()
            case .references: ReferencesList()
            case .repl: REPLView()
            case .debug: DebugPanel()
            }
        }
    }
}

struct ProblemsList: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let problems = workspace.allProblems
        if problems.isEmpty {
            Text("No problems")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(problems) { item in
                Button { workspace.reveal(item) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: Self.symbol(item.diagnostic.severity))
                            .foregroundStyle(Self.color(item.diagnostic.severity))
                        Text("\(item.fileName):\(item.diagnostic.start.line + 1):\(item.diagnostic.start.character + 1)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(item.diagnostic.message)
                            .lineLimit(2)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

struct REPLView: View {
    @Environment(Workspace.self) private var workspace
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(workspace.replOutput.isEmpty
                             ? "Type Java below and press ↩ (jshell) — or select code in the editor and press ⌃↩ to send it."
                             : workspace.replOutput)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(workspace.replOutput.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: workspace.replOutput) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            HStack(spacing: 6) {
                Text("jshell>").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                TextField("Java expression, statement or /command", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) { recall(-1); return .handled }
                    .onKeyPress(.downArrow) { recall(1); return .handled }
                Button { workspace.interruptREPL() } label: { Image(systemName: "stop.circle") }
                    .buttonStyle(.borderless).help("Interrupt (KeyboardInterrupt)")
                    .disabled(!workspace.isREPLRunning)
                Button { workspace.restartREPL() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Restart JShell")
                Button { workspace.clearREPL() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Clear")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .onAppear {
            workspace.startREPL()
            inputFocused = true
        }
    }

    private func submit() {
        let line = input
        if !line.trimmingCharacters(in: .whitespaces).isEmpty, history.last != line { history.append(line) }
        historyIndex = nil
        input = ""
        workspace.sendREPLLine(line)
        inputFocused = true
    }

    private func recall(_ delta: Int) {
        guard !history.isEmpty else { return }
        let next = (historyIndex ?? history.count) + delta
        if next >= history.count {
            historyIndex = nil
            input = ""
        } else {
            historyIndex = max(next, 0)
            input = history[historyIndex!]
        }
    }
}

struct ReferencesList: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.references.isEmpty {
            Text("No references. Right-click a symbol → Find References (⌥⌘R).")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(workspace.references) { item in
                Button { workspace.openReference(item) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(item.fileName):\(item.position.line + 1)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(Self.highlight(item.lineText, word: workspace.referencesQuery))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(workspace.relativePath(item.url))
            }
            .listStyle(.plain)
        }
    }

    private static func highlight(_ line: String, word: String) -> AttributedString {
        var text = AttributedString(line)
        guard !word.isEmpty else { return text }
        var searchStart = text.startIndex
        while let range = text[searchStart...].range(of: word) {
            text[range].font = .system(.body, design: .monospaced).bold()
            text[range].backgroundColor = Color.yellow.opacity(0.3)
            searchStart = range.upperBound
        }
        return text
    }
}

extension ProblemsList {
    static func symbol(_ severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    static func color(_ severity: Diagnostic.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .yellow
        default: .blue
        }
    }
}

struct OutputView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            if workspace.runSessions.count > 1 {
                RunSessionTabs()
                Divider()
            }
            if let session = workspace.selectedRun {
                RunSessionView(session: session)
                    .id(session.id)
            } else {
                Text("No output yet. Use Run (⌘R), Test (⌘U) or Build (⌘B).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// One chip per Run / Build / Test session.
struct RunSessionTabs: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(workspace.runSessions) { session in
                    let selected = session.id == workspace.selectedRun?.id
                    HStack(spacing: 4) {
                        Circle()
                            .fill(session.isRunning ? Color.green : (session.exitStatus.map { $0 == 0 || $0 == 130 } ?? true) ? Color.secondary.opacity(0.4) : Color.red)
                            .frame(width: 7, height: 7)
                        Text(session.title).font(.caption).lineLimit(1)
                        Button {
                            workspace.closeRunSession(session)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .help(session.isRunning ? "Stop and close" : "Close")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { workspace.selectedRunID = session.id }
                    .contextMenu {
                        if session.isRunning { Button("Stop") { session.stop() } }
                        Button("Clear") { session.clear() }
                        Button("Close") { workspace.closeRunSession(session) }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
    }
}

struct RunSessionView: View {
    @Environment(Workspace.self) private var workspace
    let session: RunSession
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(OutputLinks.attributed(session.output))
                            .font(.system(.body, design: .monospaced))
                            .environment(\.openURL, OpenURLAction { url in
                                workspace.openOutputLink(url)
                                return .handled
                            })
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: session.output) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            if session.isRunning {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    TextField("stdin — type input for the program and press ↩", text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .focused($inputFocused)
                        .onSubmit {
                            session.send(input)
                            input = ""
                            inputFocused = true
                        }
                    Button("EOF") { session.sendEOF() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Close stdin (Ctrl-D)")
                    Button("Stop") { session.stop() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
    }
}
