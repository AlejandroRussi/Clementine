import AppKit

if let i = CommandLine.arguments.firstIndex(of: "--cli") {
    let args = Array(CommandLine.arguments[(i + 1)...])
    Task {
        let code = await CLI.run(args)
        exit(code)
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
