# JavaIDE

A native macOS IDE for Java, written in Swift (SwiftUI + AppKit).
Sibling project of [golang-ide](https://github.com/lai3d/golang-ide), [python-ide](https://github.com/lai3d/python-ide) and [database-ide](https://github.com/lai3d/database-ide), sharing the same LSP-client architecture. Language intelligence comes from the Eclipse JDT language server (**jdtls**), the engine behind VS Code's Java support.

> Early scaffold — usable for editing small Maven, Gradle and plain-`javac` projects, not yet a daily driver.

## Features

- Project sidebar (open any folder; hides `target`, `build`, `.gradle`, `out`, IDE folders) that updates live, plus an **Outline** mode listing the current file's classes, methods and fields (click to jump)
- **Tabs** for multiple open files: each keeps its own caret, scroll position and undo history; ⌘W closes (asks to save), ⇧⌘] / ⇧⌘[ switch, ⌥⌘S saves all
- **Line-number gutter** with the caret line highlighted and red/yellow dots on lines with errors/warnings
- Java syntax highlighting (keywords, contextual `var`/`record`/`yield`/`sealed`, annotations, text blocks, types, constants), find bar, undo
- Java editing: 4-space soft tabs, auto-indent after `{` / `(` / `->` / `case …:`, ↩ between `{}` opens the block, ↩ after an unclosed `{` adds the `}`, typing `}` re-aligns it with its `{`, Javadoc ` * ` continuation, ⇥/⇧⇥ indent/dedent lines, ⌘/ toggles `//` comments
- **jdtls** over LSP:
  - live diagnostics as you type, shown as underlines and in the Problems panel
  - **completion** as you type identifiers or `.` (or press Esc), with auto-import edits
  - **hover** for signatures and Javadoc
  - **go to definition**: ⌘-click or ⌥⌘B, back with ⌃⌘←. JDK and library classes open as read-only source (attached sources, or decompiled)
  - **signature help** while typing a call
  - **find references** (⌥⌘R) and **rename symbol** (⌃⌘E) across the project; changed files open as unsaved tabs
  - **quick fixes** with ⌥↩ (or right-click ▸ Show Quick Fixes): add import, create method/field, add `throws`, surround with try/catch, generate `toString()`…
  - **Format Document** (⌥⌘L) with the Eclipse formatter and **Organize Imports** (⌃⌥O); both optionally on save (*Code* menu)
- **Build systems**, detected from the project root:
  - **Maven** (`pom.xml`, uses `./mvnw` if present): Run = `mvn compile exec:java -Dexec.mainClass=…`, Test = `mvn test` (or `-Dtest=` the current test class), Build = `mvn test-compile`
  - **Gradle** (`build.gradle[.kts]`, uses `./gradlew` if present): Run = `gradle run` with the application plugin, else `classes` + `java`; Test = `gradle test [--tests …]`
  - **Plain sources**: compiles every non-test `.java` file with `javac` into a cache folder (your project stays clean) and runs the class
- Run (⌘R) runs the current class if it has a `main` method, else the first one found; Build (⌘B), Test (⌘U), Stop (⌘.)
- **Debugger** (Microsoft's java-debug, running inside jdtls): click a line number (or ⌘F8) for a breakpoint, right-click it for a **conditional breakpoint**; **Debug** (⇧⌘D or the ladybug) launches the current class (Maven/Gradle dependencies on the class path) and pauses on breakpoints and uncaught exceptions. Continue ⌃⌘Y, Step Over F8, Into F7, Out ⇧F8, Stop ⌘.; the Debug panel shows the call stack, expandable variables, and a console that evaluates Java expressions in the selected frame (or feeds the program's stdin while it runs). The first Debug asks to download the java-debug plugin (~3 MB, checksum-verified) from Maven Central into `~/Library/Application Support/JavaIDE/java-debug`
- Output panel with a **stdin field** while a program runs, so `Scanner(System.in)` works (plus an EOF button)
- **JShell panel** (⌃⌘P) with the project's compiled classes on the class path; **Send Selection to JShell** (⌃↩)
- **JDK picker** in the status bar and *Java ▸ JDK*: lists every JDK registered with macOS (`/usr/libexec/java_home -V`), or browse for one. The chosen JDK is used for running, building and JShell, and is passed to jdtls as the project runtime
- *File ▸ New Java Class…* (⌘N) creates a class / `interface:Name` / `enum:Name` / `record:Name` with the right `package` line

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16 or later)
- A JDK (17+ recommended): `brew install openjdk`, or any JDK in `/Library/Java/JavaVirtualMachines`
- jdtls: `brew install jdtls` (it brings its own JDK 21+ to run on)
- Optional: `maven` / `gradle` (`brew install maven gradle`) if your projects don't ship `mvnw` / `gradlew`

For scripted testing, `JAVAIDE_BREAKPOINTS="Main.java:9"` sets breakpoints (path relative to the folder, 1-based line) when a folder is opened from the command line.

JavaIDE looks for tools on `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and SDKMAN's folders, so it works when launched from Finder too. jdtls keeps its per-project index in `~/Library/Caches/JavaIDE/` (*Java ▸ Clean Language Server Workspace* resets it).

## Build & run

```sh
swift run JavaIDE Examples/hello        # plain sources
swift run JavaIDE Examples/maven-demo   # Maven + JUnit 5
swift test                              # unit tests + jdtls and debugger end-to-end tests
./scripts/bundle.sh                     # build build/JavaIDE.app (release, ad-hoc signed)
open build/JavaIDE.app
```

The first time jdtls opens a Maven or Gradle project it imports it (downloading dependencies), which can take a while; the status bar shows progress.

## Layout

| Path | What |
|---|---|
| `Sources/JavaIDECore` | UI-independent core: JSON-RPC/LSP client, DAP client (stdio or TCP), java-debug installer, message framing, Java highlighter & indent rules, JDK / jdtls / build-system discovery, run commands, code actions, LSP position math, file tree |
| `Sources/JavaIDE` | SwiftUI app: workspace state, editor view, sidebar, panels |
| `Tests/JavaIDECoreTests` | swift-testing tests (the jdtls / debugger tests run when `jdtls` and the java-debug jar are installed) |
| `Examples/hello` | Plain-javac project |
| `Examples/maven-demo` | Maven project with a JUnit 5 test |

## Roadmap

- Debugger: watch expressions, hot code replace, attach to a running JVM
- Clickable stack traces and compiler errors in the Output panel
- Test explorer with per-method runs
- Maven/Gradle dependency tree sidebar

## License

MIT — see [LICENSE](LICENSE).
