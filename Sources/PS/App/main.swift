import AppKit

// Tooling flags used by scripts/build-app.sh and scripts/measure.sh.
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--export-iconset"), index + 1 < arguments.count {
    AppIcon.exportIconset(to: URL(fileURLWithPath: arguments[index + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
