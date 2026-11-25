import AVFoundation
import WatchKit

/// Google's three voice states.
enum VoiceMode: String, CaseIterable, Identifiable {
    case on, alertsOnly, muted
    var id: String { rawValue }
    var label: String {
        switch self {
        case .on: "Voice on"
        case .alertsOnly: "Alerts only"
        case .muted: "Muted"
        }
    }
    var symbol: String {
        switch self {
        case .on: "speaker.wave.2.fill"
        case .alertsOnly: "speaker.badge.exclamationmark.fill"
        case .muted: "speaker.slash.fill"
        }
    }
    var next: VoiceMode {
        switch self {
        case .on: .alertsOnly
        case .alertsOnly: .muted
        case .muted: .on
        }
    }
}

enum HapticLevel: String, CaseIterable, Identifiable {
    case all, turnsOnly, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All taps"
        case .turnsOnly: "Turns only"
        case .off: "Off"
        }
    }
    var symbol: String {
        switch self {
        case .all: "hand.tap.fill"
        case .turnsOnly: "arrow.triangle.turn.up.right.circle.fill"
        case .off: "hand.raised.slash.fill"
        }
    }
}

/// Voice prompts + wrist taps, tuned so you can navigate without looking:
/// • approaching a turn: one soft tap
/// • turn RIGHT now: a steady run of taps (tick-tick-tick-tick)
/// • turn LEFT now: taps in pairs (tick-tick · tick-tick · tick-tick)
/// • arrived: success chime, rerouting: retry pattern
@MainActor
final class Guidance: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Guidance()

    private let synth = AVSpeechSynthesizer()
    private var hapticTask: Task<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    var voiceMode: VoiceMode {
        get { VoiceMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.voiceMode) ?? "") ?? .on }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.voiceMode); if newValue == .muted { stopSpeaking() } }
    }

    var hapticLevel: HapticLevel {
        get { HapticLevel(rawValue: UserDefaults.standard.string(forKey: SettingsKey.hapticLevel) ?? "") ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.hapticLevel) }
    }

    /// Kept for older call sites (mute toggle).
    var muted: Bool {
        get { voiceMode == .muted }
        set { voiceMode = newValue ? .muted : .on }
    }

    enum Priority { case info, maneuver, alert }

    func speak(_ text: String, interrupt: Bool = false, priority: Priority = .maneuver) {
        guard !text.isEmpty else { return }
        switch voiceMode {
        case .muted: return
        case .alertsOnly where priority == .info: return
        default: break
        }
        if interrupt, synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.rate = Float(UserDefaults.standard.double(forKey: SettingsKey.voiceRate))
        u.prefersAssistiveTechnologySettings = true
        u.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(u)
    }

    func stopSpeaking() { synth.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.synth.isSpeaking { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
    }

    enum Tap { case prepare, left, right, straight, arrive, reroute, start, end, warning, select, toggleOn, toggleOff }

    func tap(_ t: Tap) {
        let level = hapticLevel
        guard level != .off else { return }
        let turnRelated: Set<Tap> = [.left, .right, .straight, .arrive, .reroute, .prepare]
        if level == .turnsOnly && !turnRelated.contains(t) { return }
        let d = WKInterfaceDevice.current()
        switch t {
        case .prepare: d.play(.notification)
        case .right: pattern([.directionUp, .directionUp, .directionUp, .directionUp], gap: 0.16)
        case .left: pattern([.directionDown, .directionDown, nil, .directionDown, .directionDown, nil, .directionDown, .directionDown], gap: 0.14)
        case .straight: pattern([.click, .click], gap: 0.2)
        case .arrive: pattern([.success, nil, .success], gap: 0.25)
        case .reroute: d.play(.retry)
        case .start: d.play(.start)
        case .end: d.play(.stop)
        case .warning: d.play(.failure)
        case .select: d.play(.click)
        case .toggleOn: d.play(.directionUp)
        case .toggleOff: d.play(.directionDown)
        }
    }

    /// Plays a sequence of taps; `nil` entries are pauses.
    private func pattern(_ steps: [WKHapticType?], gap: Double) {
        hapticTask?.cancel()
        hapticTask = Task { @MainActor in
            for s in steps {
                if Task.isCancelled { return }
                if let s { WKInterfaceDevice.current().play(s) }
                try? await Task.sleep(for: .seconds(gap))
            }
        }
    }
}
