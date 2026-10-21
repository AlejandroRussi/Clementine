import AppKit

if let i = CommandLine.arguments.firstIndex(of: "--cli") {
    let args = Array(CommandLine.arguments[(i + 1)...])
    Task {
        let code = await CLI.run(args)
        exit(code)
    }
    // Keep the real main thread serving the main queue (WebKit must start on it);
    // dispatchMain() would park it and drain main-queue work on a worker thread.
    while true { RunLoop.main.run() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
