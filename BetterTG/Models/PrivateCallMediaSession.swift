import AVFoundation
import Foundation
import TDLibKit
import TgVoipWebrtcBetterTGDynamic

/// Owns the native tgcalls/WebRTC engine for one TDLib private call.
final class PrivateCallMediaSession: @unchecked Sendable {
    private final class EngineQueue: NSObject, OngoingCallThreadLocalContextQueueWebrtc {
        private let queue = DispatchQueue(label: "com.mihaipascu.BetterTG.private-call-media", qos: .userInitiated)
        private let key = DispatchSpecificKey<Void>()

        override init() {
            super.init()
            queue.setSpecific(key: key, value: ())
        }

        func dispatch(_ f: @escaping () -> Void) {
            queue.async(execute: f)
        }

        func sync<T>(_ f: () throws -> T) rethrows -> T {
            try queue.sync(execute: f)
        }

        func isCurrent() -> Bool {
            DispatchQueue.getSpecific(key: key) != nil
        }

        func scheduleBlock(_ f: @escaping () -> Void, after timeout: Double) -> GroupCallDisposable {
            let item = DispatchWorkItem(block: f)
            queue.asyncAfter(deadline: .now() + timeout, execute: item)
            return GroupCallDisposable { item.cancel() }
        }
    }

    let callId: Int
    private let service: any TelegramService
    private let queue = EngineQueue()
    private var context: OngoingCallThreadLocalContextWebrtc?
    private var videoCapturer: OngoingCallThreadLocalContextVideoCapturer?
    private var cameraPosition: AVCaptureDevice.Position = .front
    private let lock = NSLock()

    init?(call: Call, ready: CallStateReady, service: any TelegramService) {
        self.callId = call.id
        self.service = service

        let nativeVersions = OngoingCallThreadLocalContextWebrtc.versions(withIncludeReference: false)
        guard let version = ready.protocol.libraryVersions.reversed().first(where: nativeVersions.contains) else {
            return nil
        }

        OngoingCallThreadLocalContextWebrtc.applyServerConfig(ready.config)
        OngoingCallThreadLocalContextWebrtc.setupAudioSession()
        configureAudioSession()

        let connections = Self.makeConnections(ready.servers)
        guard !connections.isEmpty else { return nil }

        let capturer: OngoingCallThreadLocalContextVideoCapturer?
        if call.isVideo,
           let camera = AVCaptureDevice.DiscoverySession(
               deviceTypes: [.builtInWideAngleCamera],
               mediaType: .video,
               position: .front
           ).devices.first
        {
            capturer = OngoingCallThreadLocalContextVideoCapturer(deviceId: camera.uniqueID, keepLandscape: false)
        } else {
            capturer = nil
        }
        videoCapturer = capturer

        let logs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BetterTGCalls", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let engine = queue.sync {
            OngoingCallThreadLocalContextWebrtc(
                version: version,
                customParameters: ready.customParameters,
                queue: queue,
                proxy: nil,
                networkType: .wifi,
                dataSaving: .never,
                derivedState: Data(),
                key: ready.encryptionKey,
                isOutgoing: call.isOutgoing,
                connections: connections,
                maxLayer: Int32(ready.protocol.maxLayer),
                allowP2P: ready.allowP2p,
                allowTCP: true,
                enableStunMarking: false,
                logPath: logs.appendingPathComponent("\(call.id).log").path,
                statsLogPath: logs.appendingPathComponent("\(call.id)-stats.json").path,
                sendSignalingData: { [weak self] data in
                    guard let self else { return }
                    Task {
                        _ = try? await self.service.sendCallSignalingData(callId: self.callId, data: data)
                    }
                },
                videoCapturer: capturer,
                preferredVideoCodec: nil,
                audioInputDeviceId: "",
                audioDevice: nil,
                directConnection: nil
            )
        }
        queue.dispatch {
            engine.setManualAudioSessionIsActive(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                let audio = AVAudioSession.sharedInstance()
                try? audio.overrideOutputAudioPort(.speaker)
            }
        }
        context = engine
    }

    func addSignalingData(_ data: Data) {
        lock.lock()
        let context = context
        lock.unlock()
        context?.addSignaling(data)
    }

    func setMuted(_ isMuted: Bool) {
        lock.lock()
        let engine = context
        lock.unlock()
        queue.dispatch { engine?.setIsMuted(isMuted) }
    }

    func setSpeakerEnabled(_ isEnabled: Bool) {
        DispatchQueue.main.async {
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isEnabled ? .speaker : .none)
        }
    }

    func setVideoEnabled(_ isEnabled: Bool) {
        lock.lock()
        let engine = context
        var capturer = videoCapturer
        lock.unlock()

        if isEnabled, capturer == nil,
           let camera = AVCaptureDevice.DiscoverySession(
               deviceTypes: [.builtInWideAngleCamera],
               mediaType: .video,
               position: .front
           ).devices.first
        {
            capturer = OngoingCallThreadLocalContextVideoCapturer(
                deviceId: camera.uniqueID,
                keepLandscape: false
            )
            lock.lock()
            videoCapturer = capturer
            cameraPosition = .front
            lock.unlock()
        }

        queue.dispatch {
            capturer?.setIsVideoEnabled(isEnabled)
            if isEnabled {
                engine?.requestVideo(capturer)
            } else {
                engine?.disableVideo()
            }
        }
    }

    func switchCamera() {
        let nextPosition: AVCaptureDevice.Position = cameraPosition == .front ? .back : .front
        guard let camera = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: nextPosition
        ).devices.first else { return }

        cameraPosition = nextPosition
        lock.lock()
        let capturer = videoCapturer
        lock.unlock()
        queue.dispatch { capturer?.switchVideoInput(camera.uniqueID) }
    }

    func stop() {
        lock.lock()
        let engine = context
        context = nil
        videoCapturer = nil
        lock.unlock()
        engine?.beginTermination()
        engine?.stop(nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try? audio.setActive(true)
        try? audio.overrideOutputAudioPort(.speaker)
    }

    private static func makeConnections(_ servers: [CallServer]) -> [OngoingCallConnectionDescriptionWebrtc] {
        let telegramIds = servers.compactMap { server -> Int64? in
            if case .callServerTypeTelegramReflector = server.type { return server.id.rawValue }
            return nil
        }.sorted()
        let idMap = Dictionary(uniqueKeysWithValues: telegramIds.enumerated().map {
            ($0.element, UInt8(clamping: $0.offset + 1))
        })

        return servers.flatMap { server -> [OngoingCallConnectionDescriptionWebrtc] in
            let endpoints = [server.ipAddress, server.ipv6Address].filter { !$0.isEmpty }
            switch server.type {
            case .callServerTypeTelegramReflector(let reflector):
                guard let reflectorId = idMap[server.id.rawValue] else { return [] }
                let password = reflector.peerTag.map { String(format: "%02x", $0) }.joined()
                return endpoints.map {
                    OngoingCallConnectionDescriptionWebrtc(
                        reflectorId: reflectorId,
                        hasStun: false,
                        hasTurn: true,
                        hasTcp: reflector.isTcp,
                        ip: $0,
                        port: Int32(server.port),
                        username: "reflector",
                        password: password
                    )
                }
            case .callServerTypeWebrtc(let webRTC):
                return endpoints.map {
                    OngoingCallConnectionDescriptionWebrtc(
                        reflectorId: 0,
                        hasStun: webRTC.supportsStun,
                        hasTurn: webRTC.supportsTurn,
                        hasTcp: false,
                        ip: $0,
                        port: Int32(server.port),
                        username: webRTC.username,
                        password: webRTC.password
                    )
                }
            }
        }
    }

    deinit {
        stop()
    }
}
