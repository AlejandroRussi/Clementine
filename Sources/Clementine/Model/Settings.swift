import AppKit
import Combine

/// Modifier chord the user taps while dragging files to summon the wheel.
enum TriggerModifier: String, CaseIterable, Identifiable {
    case option, control, optionShift, controlOption, commandShift

    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: return [.option]
        case .control: return [.control]
        case .optionShift: return [.option, .shift]
        case .controlOption: return [.control, .option]
        case .commandShift: return [.command, .shift]
        }
    }

    var label: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .optionShift: return "⌥⇧ Option + Shift"
        case .controlOption: return "⌃⌥ Control + Option"
        case .commandShift: return "⌘⇧ Command + Shift"
        }
    }
}

enum CompressionStrength: String, CaseIterable, Identifiable {
    case light, balanced, strong
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var jpegQuality: Double { switch self { case .light: 0.82; case .balanced: 0.65; case .strong: 0.45 } }
    var maxImageDimension: CGFloat? { switch self { case .light: nil; case .balanced: 3000; case .strong: 1920 } }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var trigger: TriggerModifier { didSet { d.set(trigger.rawValue, forKey: "trigger") } }
    @Published var compression: CompressionStrength { didSet { d.set(compression.rawValue, forKey: "compression") } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: "playSound") } }
    @Published var revealResults: Bool { didSet { d.set(revealResults, forKey: "revealResults") } }
    @Published var preserveMetadata: Bool { didSet { d.set(preserveMetadata, forKey: "preserveMetadata") } }
    @Published var hasSeenWelcome: Bool { didSet { d.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }

    private init() {
        trigger = TriggerModifier(rawValue: d.string(forKey: "trigger") ?? "") ?? .option
        compression = CompressionStrength(rawValue: d.string(forKey: "compression") ?? "") ?? .balanced
        playSound = d.object(forKey: "playSound") as? Bool ?? true
        revealResults = d.object(forKey: "revealResults") as? Bool ?? false
        preserveMetadata = d.object(forKey: "preserveMetadata") as? Bool ?? true
        hasSeenWelcome = d.bool(forKey: "hasSeenWelcome")
    }
}
