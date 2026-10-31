import AppKit

let arguments = CommandLine.arguments

MainActor.assumeIsolated {
    if ["--dump", "--render", "--shots", "--video", "--video-stills"].contains(where: arguments.contains) {
        DebugRunner.run(arguments)
    } else {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
