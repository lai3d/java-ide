import AppKit
import SwiftUI
import JavaIDECore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a dead language server's stdin must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    weak var workspace: Workspace?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        return workspace.confirmDiscardOrSave(workspace.documents) ? .terminateNow : .terminateCancel
    }
}

@main
struct JavaIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace = Workspace()

    init() {
        // Don't restore window state: a saved "no windows open" state (e.g. after the app was killed)
        // would otherwise relaunch it with no window at all. The workspace reopens its own folder.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    var body: some Scene {
        WindowGroup("JavaIDE") {
            ContentView()
                .environment(workspace)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { appDelegate.workspace = workspace }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { workspace.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { workspace.closeCurrentTab() }
                    .keyboardShortcut("w")
                    .disabled(workspace.currentFile == nil)
                Button("Save") { workspace.save() }
                    .keyboardShortcut("s")
                    .disabled(workspace.currentFile == nil)
                Button("Save All") { workspace.saveAll() }
                    .keyboardShortcut("s", modifiers: [.option, .command])
                    .disabled(!workspace.hasUnsavedChanges)
            }
            CommandGroup(after: .newItem) {
                Button("New Java Class…") { workspace.newJavaClass() }
                    .keyboardShortcut("n")
                    .disabled(workspace.rootURL == nil)
            }
            CommandMenu("Navigate") {
                Button("Jump to Definition") {
                    Task { await workspace.jumpToDefinition(at: workspace.caretOffset) }
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!workspace.isJavaFile)
                Button("Find References") {
                    Task { await workspace.findReferences(at: workspace.caretOffset) }
                }
                .keyboardShortcut("r", modifiers: [.option, .command])
                .disabled(!workspace.isJavaFile)
                Button("Rename Symbol…") {
                    Task { await workspace.renameSymbol(at: workspace.caretOffset) }
                }
                .keyboardShortcut("e", modifiers: [.control, .command])
                .disabled(!workspace.isJavaFile || workspace.isReadOnly)
                Divider()
                Button("Go Back") { workspace.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                    .disabled(!workspace.canGoBack)
                Divider()
                Button("Next Tab") { workspace.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.shift, .command])
                    .disabled(workspace.documents.count < 2)
                Button("Previous Tab") { workspace.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.shift, .command])
                    .disabled(workspace.documents.count < 2)
            }
            CommandMenu("Code") {
                Button("Show Quick Fixes") { workspace.requestQuickFixes() }
                    .keyboardShortcut(.return, modifiers: [.option])
                    .disabled(!workspace.isJavaFile || workspace.isReadOnly)
                Divider()
                Button("Format Document") { workspace.formatDocument() }
                    .keyboardShortcut("l", modifiers: [.option, .command])
                    .disabled(!workspace.isJavaFile || workspace.isReadOnly)
                Button("Organize Imports") { workspace.organizeImportsInCurrentDocument() }
                    .keyboardShortcut("o", modifiers: [.control, .option])
                    .disabled(!workspace.isJavaFile || workspace.isReadOnly)
                Toggle("Format on Save", isOn: Bindable(workspace).formatOnSave)
                Toggle("Organize Imports on Save", isOn: Bindable(workspace).organizeImportsOnSave)
            }
            CommandMenu("Run") {
                Button("Run") { workspace.run(.run) }
                    .keyboardShortcut("r")
                    .disabled(workspace.rootURL == nil || workspace.isRunning)
                Button("Build") { workspace.run(.build) }
                    .keyboardShortcut("b")
                    .disabled(workspace.rootURL == nil || workspace.isRunning)
                Button("Test") { workspace.run(.test) }
                    .keyboardShortcut("u")
                    .disabled(workspace.rootURL == nil || workspace.isRunning)
                Divider()
                Button("Stop") { workspace.stopRun() }
                    .keyboardShortcut(".")
                    .disabled(!workspace.isRunning)
                Divider()
                Button("Open JShell") {
                    workspace.bottomTab = .repl
                    workspace.startREPL()
                }
                .keyboardShortcut("p", modifiers: [.control, .command])
                .disabled(workspace.rootURL == nil)
                Button("Send Selection to JShell") { workspace.sendSelectionToREPL() }
                    .keyboardShortcut(.return, modifiers: [.control])
                    .disabled(!workspace.isJavaFile)
                Button("Restart JShell") { workspace.restartREPL() }
                    .disabled(workspace.rootURL == nil)
            }
            CommandMenu("Debug") {
                Button("Debug") { Task { await workspace.startDebugging() } }
                    .keyboardShortcut("d", modifiers: [.shift, .command])
                    .disabled(workspace.rootURL == nil || workspace.isDebugging || workspace.isRunning)
                Button("Attach to JVM…") { Task { await workspace.attachToJVM() } }
                    .disabled(workspace.rootURL == nil || workspace.isDebugging)
                Button("Stop Debugging") { workspace.stopDebugging() }
                    .disabled(!workspace.isDebugging)
                Button("Hot Swap Changed Classes") { workspace.hotSwapNow() }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF10FunctionKey)!)), modifiers: [.command])
                    .disabled(!workspace.isDebugging)
                Divider()
                Button("Continue") { workspace.debugSession?.resume() }
                    .keyboardShortcut("y", modifiers: [.control, .command])
                    .disabled(workspace.debugSession?.isStopped != true)
                Button("Pause") { workspace.debugSession?.pause() }
                    .disabled(workspace.debugSession?.state != .running)
                Button("Step Over") { workspace.debugSession?.stepOver() }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [])
                    .disabled(workspace.debugSession?.isStopped != true)
                Button("Step Into") { workspace.debugSession?.stepIn() }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)), modifiers: [])
                    .disabled(workspace.debugSession?.isStopped != true)
                Button("Step Out") { workspace.debugSession?.stepOut() }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [.shift])
                    .disabled(workspace.debugSession?.isStopped != true)
                Divider()
                Button("Toggle Breakpoint") { workspace.toggleBreakpointAtCaret() }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [.command])
                    .disabled(!workspace.isJavaFile)
                Button("Clear All Breakpoints") { workspace.clearAllBreakpoints() }
                    .disabled(workspace.breakpoints.isEmpty)
            }
            CommandMenu("Java") {
                Menu("JDK") {
                    ForEach(JDK.installed(), id: \.home) { jdk in
                        Button(jdk.label + (jdk.home == workspace.jdk?.home ? " ✓" : "")) { workspace.chooseJDK(jdk) }
                    }
                    Divider()
                    Button("Other JDK…") { workspace.presentJDKPanel() }
                }
                Divider()
                Button("Restart Language Server") { Task { await workspace.restartLanguageServer() } }
                    .disabled(workspace.rootURL == nil)
                Button("Clean Language Server Workspace") { Task { await workspace.cleanLanguageServerWorkspace() } }
                    .disabled(workspace.rootURL == nil)
            }
        }
    }
}
