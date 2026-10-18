import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Drag to convert") {
                Picker("Trigger while dragging", selection: $settings.trigger) {
                    ForEach(TriggerModifier.allCases) { Text($0.label).tag($0) }
                }
                Text("Start dragging files in Finder, then tap the trigger keys. Drop the files on an action in the wheel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                Picker("Compression", selection: $settings.compression) {
                    ForEach(CompressionStrength.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Keep photo metadata when converting", isOn: $settings.preserveMetadata)
                Toggle("Reveal results in Finder", isOn: $settings.revealResults)
                Toggle("Play sound when finished", isOn: $settings.playSound)
                Text("Results are saved beside the original files. Originals are never changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Optional encoders") {
                LabeledContent("ffmpeg (MP3, FLAC, MKV, WebM)", value: ExternalTools.ffmpeg == nil ? "Not installed" : "Found")
                LabeledContent("cwebp (WebP fallback)", value: ExternalTools.cwebp == nil ? "Not installed" : "Found")
                Text("Install with Homebrew: brew install ffmpeg webp").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

struct WelcomeView: View {
    let onDone: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Welcome to Clementine").font(.title).bold()
            VStack(alignment: .leading, spacing: 12) {
                Label("Step 1. Drag files in Finder.", systemImage: "hand.draw")
                Label("Step 2. While dragging, tap \(Settings.shared.trigger.label).", systemImage: "keyboard")
                Label("Step 3. Drop on a format or tool in the wheel.", systemImage: "circle.grid.cross")
                Label("Or drop files on the menu bar icon, then click an action.", systemImage: "menubar.arrow.up.rectangle")
            }
            .font(.body)
            Text("Find the Clementine icon near the clock in your menu bar.").font(.caption).foregroundStyle(.secondary)
            Button("Get Started", action: onDone).keyboardShortcut(.defaultAction).controlSize(.large)
        }
        .padding(32)
        .frame(width: 440)
    }
}

@MainActor
enum Windows {
    private static var settingsWindow: NSWindow?
    private static var welcomeWindow: NSWindow?

    static func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Clementine Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    static func showWelcome() {
        let w = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView {
            Settings.shared.hasSeenWelcome = true
            welcomeWindow?.close()
        }))
        w.title = "Welcome"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        welcomeWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
