import AVFoundation
import Foundation
import TDLibKit
import TgVoipWebrtcBetterTGDynamic
import UIKit

/// Owns the native tgcalls/WebRTC engine for one TDLib private call.
final class PrivateCallMediaSession: @unchecked Sendable {
    private enum AudioRoutingPreference {
        case automatic
        case speaker
        case receiver
        case external
    }

    /// Advertise exactly the implementations registered by the bundled tgcalls
    /// framework, matching Telegram iOS instead of maintaining a stale list.
    static var supportedProtocol: CallProtocol {
        CallProtocol(
        libraryVersions: OngoingCallThreadLocalContextWebrtc.versions(withIncludeReference: false),
        maxLayer: Int(OngoingCallThreadLocalContextWebrtc.maxLayer()),
        minLayer: 65,
        udpP2p: true,
        udpReflector: true
        )
    }

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
    private var remoteVideoActiveHandler: (@Sendable (Bool) -> Void)?
    private var isRemoteVideoActive = false
    private var cameraPosition: AVCaptureDevice.Position = .front
    private var audioObservers = [NSObjectProtocol]()
    private var audioRoutingPreference = AudioRoutingPreference.automatic
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
        engine.stateChanged = { [weak self] _, _, remoteVideoState, _, _, _ in
            self?.notifyRemoteVideoActive(remoteVideoState == .active)
        }
        queue.dispatch { [weak self] in
            engine.setManualAudioSessionIsActive(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                self?.applyAudioRoutingPreference()
            }
        }
        context = engine
        startProximityMonitoring()
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            audioRoutingPreference = isEnabled ? .speaker : .receiver
            let audio = AVAudioSession.sharedInstance()
            if isEnabled {
                try? audio.setPreferredInput(nil)
            } else if let builtInInput = audio.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? audio.setPreferredInput(builtInInput)
            }
            try? audio.overrideOutputAudioPort(isEnabled ? .speaker : .none)
        }
    }

    func selectAudioInput(_ input: AVAudioSessionPortDescription) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            audioRoutingPreference = .external
            let audio = AVAudioSession.sharedInstance()
            try? audio.overrideOutputAudioPort(.none)
            try? audio.setPreferredInput(input)
        }
    }

    func setRemoteVideoActiveHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        remoteVideoActiveHandler = handler
        let isActive = isRemoteVideoActive
        lock.unlock()
        handler(isActive)
    }

    func makeIncomingVideoView(
        completion: @escaping @Sendable ((UIView & OngoingCallThreadLocalContextWebrtcVideoView)?) -> Void
    ) {
        lock.lock()
        let engine = context
        lock.unlock()

        guard let engine else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        queue.dispatch {
            engine.makeIncomingVideoView(completion)
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
        stopProximityMonitoring()
        lock.lock()
        let engine = context
        context = nil
        videoCapturer = nil
        remoteVideoActiveHandler = nil
        lock.unlock()
        engine?.beginTermination()
        engine?.stop(nil)
        DispatchQueue.main.async {
            let audio = AVAudioSession.sharedInstance()
            try? audio.overrideOutputAudioPort(.none)
            try? audio.setPreferredInput(nil)
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(.soloAmbient, mode: .default)
        }
    }

    private func startProximityMonitoring() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UIDevice.current.isProximityMonitoringEnabled = true
            audioObservers = [
                NotificationCenter.default.addObserver(
                    forName: UIDevice.proximityStateDidChangeNotification,
                    object: UIDevice.current,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateBuiltInAudioRouteForProximity()
                    }
                },
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.routeChangeNotification,
                    object: AVAudioSession.sharedInstance(),
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateBuiltInAudioRouteForProximity()
                    }
                },
            ]
            applyAudioRoutingPreference()
        }
    }

    private func stopProximityMonitoring() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            audioObservers.forEach(NotificationCenter.default.removeObserver)
            audioObservers.removeAll()
            UIDevice.current.isProximityMonitoringEnabled = false
        }
    }

    @MainActor private func updateBuiltInAudioRouteForProximity() {
        guard audioRoutingPreference == .automatic else { return }
        applyAudioRoutingPreference()
    }

    @MainActor private func applyAudioRoutingPreference() {
        let audio = AVAudioSession.sharedInstance()
        switch audioRoutingPreference {
        case .automatic:
            guard let output = audio.currentRoute.outputs.first,
                  output.portType == .builtInSpeaker || output.portType == .builtInReceiver
            else { return }
            try? audio.overrideOutputAudioPort(UIDevice.current.proximityState ? .none : .speaker)
        case .speaker:
            try? audio.setPreferredInput(nil)
            try? audio.overrideOutputAudioPort(.speaker)
        case .receiver:
            if let builtInInput = audio.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? audio.setPreferredInput(builtInInput)
            }
            try? audio.overrideOutputAudioPort(.none)
        case .external:
            break
        }
    }

    private func notifyRemoteVideoActive(_ isActive: Bool) {
        lock.lock()
        isRemoteVideoActive = isActive
        let handler = remoteVideoActiveHandler
        lock.unlock()
        handler?(isActive)
    }

    private func configureAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
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
