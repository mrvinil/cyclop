import AppKit

protocol TimerSoundPlaying {
    func playCompletion()
}

struct SystemTimerSoundPlayer: TimerSoundPlaying {
    func playCompletion() {
        NSSound(named: "Glass")?.play()
    }
}
