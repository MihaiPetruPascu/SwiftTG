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
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
            )
            try session.setActive(true)
            startOutgoingCallProximityMonitoring()
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            callToneEngine = engine
            callTonePlayer = player
        } catch {
            stopOutgoingCallProximityMonitoring()
            engine.stop()
        }
    }

    func stopOutgoingCallTone(deactivateAudioSession: Bool = true) {
        stopOutgoingCallProximityMonitoring()
        callTonePlayer?.stop()
        callToneEngine?.stop()
        callTonePlayer = nil
        callToneEngine = nil
        if deactivateAudioSession {
            let audio = AVAudioSession.sharedInstance()
            try? audio.overrideOutputAudioPort(.none)
            try? audio.setPreferredInput(nil)
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(.soloAmbient, mode: .default)
        }
    }

    func startCallConnectingTone() {
        guard connectingCallPlayer == nil,
              let player = makeCallSoundPlayer(named: "voip_connecting")
        else { return }
        player.numberOfLoops = -1
        player.play()
        connectingCallPlayer = player
    }

    func playCallConnectedSound() {
        stopCallConnectingTone()
        guard let player = makeCallSoundPlayer(named: "voip_connected") else { return }
        player.play()
        callFeedbackPlayer = player
    }

    func playCallEndedSound() {
        stopCallConnectingTone()
        guard let player = makeCallSoundPlayer(named: "voip_end") else { return }
        player.play()
        callFeedbackPlayer = player
    }

    func stopCallConnectingTone() {
        connectingCallPlayer?.stop()
        connectingCallPlayer = nil
    }

    func startIncomingCallTone() {
        guard incomingCallToneEngine == nil else { return }

        let sampleRate = 44_100.0
        let duration = 3.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(sampleRate * duration)
              ),
              let samples = buffer.floatChannelData?[0]
        else { return }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0 ..< Int(buffer.frameLength) {
            let time = Double(frame) / sampleRate
            let cycleTime = time.truncatingRemainder(dividingBy: 1.5)
            guard cycleTime < 0.8 else {
                samples[frame] = 0
                continue
            }
            let fade = min(1, min(cycleTime / 0.02, (0.8 - cycleTime) / 0.02))
            samples[frame] = Float((sin(2 * .pi * 440 * time) + sin(2 * .pi * 480 * time)) * 0.12 * fade)
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
            incomingCallToneEngine = engine
            incomingCallTonePlayer = player
        } catch {
            engine.stop()
        }
    }

    func stopIncomingCallTone(deactivateAudioSession: Bool = true) {
        incomingCallTonePlayer?.stop()
        incomingCallToneEngine?.stop()
        incomingCallTonePlayer = nil
        incomingCallToneEngine = nil
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Private

    private var incomingMessageSound: SystemSoundID = 0
    private var messageDeliveredSound: SystemSoundID = 0
    private var callToneEngine: AVAudioEngine?
    private var callTonePlayer: AVAudioPlayerNode?
    private var connectingCallPlayer: AVAudioPlayer?
    private var callFeedbackPlayer: AVAudioPlayer?
    private var outgoingCallProximityObserver: NSObjectProtocol?
    private var incomingCallToneEngine: AVAudioEngine?
    private var incomingCallTonePlayer: AVAudioPlayerNode?
    private var policy = TelegramServiceSoundPolicy()

    private func makeCallSoundPlayer(named name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3"),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return nil }
        player.prepareToPlay()
        return player
    }

    private func startOutgoingCallProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = true
        outgoingCallProximityObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification,
            object: UIDevice.current,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ServiceSoundManager.shared.updateOutgoingCallAudioRoute()
            }
        }
        updateOutgoingCallAudioRoute()
    }

    private func stopOutgoingCallProximityMonitoring() {
        if let outgoingCallProximityObserver {
            NotificationCenter.default.removeObserver(outgoingCallProximityObserver)
            self.outgoingCallProximityObserver = nil
        }
        UIDevice.current.isProximityMonitoringEnabled = false
    }

    private func updateOutgoingCallAudioRoute() {
        let audio = AVAudioSession.sharedInstance()
        guard let output = audio.currentRoute.outputs.first,
              output.portType == .builtInSpeaker || output.portType == .builtInReceiver
        else { return }
        try? audio.overrideOutputAudioPort(UIDevice.current.proximityState ? .none : .speaker)
    }

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
