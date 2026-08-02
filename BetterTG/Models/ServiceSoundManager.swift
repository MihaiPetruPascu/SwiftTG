// ServiceSoundManager.swift

import AudioToolbox
import AVFoundation
import UIKit

@MainActor final class ServiceSoundManager {
    // MARK: Lifecycle

    private init() {
        self.messageDeliveredSound = loadSound(
            named: TelegramServiceSoundPolicy.deliveredResourceName,
            extension: TelegramServiceSoundPolicy.resourceExtension,
        )
        self.incomingMessageSound = loadSound(
            named: TelegramServiceSoundPolicy.incomingResourceName,
            extension: TelegramServiceSoundPolicy.resourceExtension,
        )
    }

    deinit {
        if messageDeliveredSound != 0 {
            AudioServicesDisposeSystemSoundID(messageDeliveredSound)
        }
        if incomingMessageSound != 0 {
            AudioServicesDisposeSystemSoundID(incomingMessageSound)
        }
    }

    // MARK: Internal

    static let shared = ServiceSoundManager()

    func playMessageDelivered() {
        guard policy.shouldPlayDelivered() else { return }
        play(messageDeliveredSound)
    }

    func playIncomingMessageIfAppropriate(isMuted: Bool) {
        guard policy.shouldPlayIncoming(
            applicationIsActive: UIApplication.shared.applicationState == .active,
            isMuted: isMuted,
        ) else { return }
        play(incomingMessageSound)
    }

    func startOutgoingCallTone() {
        guard callToneEngine == nil else { return }

        let sampleRate = 44_100.0
        let duration = 6.0
        let audibleDuration = 2.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(sampleRate * duration),
              ),
              let samples = buffer.floatChannelData?[0]
        else { return }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0 ..< Int(buffer.frameLength) {
            let time = Double(frame) / sampleRate
            guard time < audibleDuration else {
                samples[frame] = 0
                continue
            }
            let edgeFade = min(1, min(time / 0.025, (audibleDuration - time) / 0.025))
            let tone = sin(2 * .pi * 440 * time) + sin(2 * .pi * 480 * time)
            samples[frame] = Float(tone * 0.10 * edgeFade)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt)
            try session.setActive(true)
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            callToneEngine = engine
            callTonePlayer = player
        } catch {
            engine.stop()
        }
    }

    func stopOutgoingCallTone() {
        callTonePlayer?.stop()
        callToneEngine?.stop()
        callTonePlayer = nil
        callToneEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Private

    private var incomingMessageSound: SystemSoundID = 0
    private var messageDeliveredSound: SystemSoundID = 0
    private var callToneEngine: AVAudioEngine?
    private var callTonePlayer: AVAudioPlayerNode?
    private var policy = TelegramServiceSoundPolicy()

    private func loadSound(named name: String, extension fileExtension: String) -> SystemSoundID {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else { return 0 }
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { return 0 }
        return sound
    }

    private func play(_ sound: SystemSoundID) {
        guard sound != 0 else { return }
        AudioServicesPlaySystemSound(sound)
    }
}
