import Combine
import Foundation
import Observation
import TDLibKit

@MainActor @Observable final class IncomingCallCoordinator {
    enum Phase: Equatable {
        case incoming
        case accepting
        case connecting
        case ready([String])
        case ending

        var title: String {
            switch self {
            case .incoming: "Incoming call"
            case .accepting: "Accepting…"
            case .connecting: "Connecting…"
            case .ready: "Connected"
            case .ending: "Ending call…"
            }
        }
    }

    static let shared = IncomingCallCoordinator(service: TDLib.shared.service)

    private(set) var isPresented = false
    private(set) var callerName = "Telegram user"
    private(set) var isVideo = false
    private(set) var phase = Phase.incoming
    var errorMessage: String?

    private let service: any TelegramService
    private var call: Call?
    private var mediaSession: PrivateCallMediaSession?
    private var connectedAt: Foundation.Date?
    private var pendingSignalingData = [Data]()
    private var acceptsNextIncomingCall = false
    private var cancellables = Set<AnyCancellable>()

    init(service: any TelegramService) {
        self.service = service
        service.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self else { return }
                switch update {
                case .updateCall(let value):
                    self.receive(value.call)
                case .updateNewCallSignalingData(let value):
                    self.receiveSignaling(callId: value.callId, data: value.data)
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    func accept() {
        guard let call else {
            acceptsNextIncomingCall = true
            return
        }
        guard phase == .incoming else { return }
        ServiceSoundManager.shared.stopIncomingCallTone()
        phase = .accepting
        Task {
            do {
                _ = try await service.acceptCall(callId: call.id, protocol: Self.supportedProtocol)
            } catch {
                errorMessage = error.localizedDescription
                reset()
            }
        }
    }

    func decline() {
        finish(disconnected: false)
    }

    func hangUp() {
        finish(disconnected: false)
    }

    func setMuted(_ muted: Bool) { mediaSession?.setMuted(muted) }
    func setSpeakerEnabled(_ enabled: Bool) { mediaSession?.setSpeakerEnabled(enabled) }
    func setVideoEnabled(_ enabled: Bool) { mediaSession?.setVideoEnabled(enabled) }
    func switchCamera() { mediaSession?.switchCamera() }

    private func receive(_ updatedCall: Call) {
        guard !updatedCall.isOutgoing else { return }

        if call == nil {
            guard case .callStatePending = updatedCall.state else { return }
            call = updatedCall
            isVideo = updatedCall.isVideo
            phase = .incoming
            isPresented = true
            ServiceSoundManager.shared.startIncomingCallTone()
            loadCallerName(userId: updatedCall.userId)
            if acceptsNextIncomingCall {
                acceptsNextIncomingCall = false
                accept()
            }
        } else {
            guard call?.id == updatedCall.id else { return }
            call = updatedCall
        }

        switch updatedCall.state {
        case .callStatePending:
            break
        case .callStateExchangingKeys:
            ServiceSoundManager.shared.stopIncomingCallTone()
            phase = .connecting
        case .callStateReady(let ready):
            ServiceSoundManager.shared.stopIncomingCallTone()
            if mediaSession == nil {
                guard let session = PrivateCallMediaSession(call: updatedCall, ready: ready, service: service) else {
                    errorMessage = "The call media engine couldn't negotiate a compatible Telegram protocol."
                    finish(disconnected: true)
                    return
                }
                mediaSession = session
                pendingSignalingData.forEach(session.addSignalingData)
                pendingSignalingData.removeAll()
            }
            connectedAt = connectedAt ?? Foundation.Date()
            phase = .ready(ready.emojis)
        case .callStateHangingUp:
            ServiceSoundManager.shared.stopIncomingCallTone()
            phase = .ending
        case .callStateDiscarded:
            reset()
        case .callStateError(let value):
            errorMessage = value.error.message
            reset()
        }
    }

    private func receiveSignaling(callId: Int, data: Data) {
        guard call?.id == callId else { return }
        if let mediaSession {
            mediaSession.addSignalingData(data)
        } else {
            pendingSignalingData.append(data)
        }
    }

    private func loadCallerName(userId: Int64) {
        Task {
            guard let user = try? await service.getUser(userId: userId), call?.userId == userId else { return }
            let fullName = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
            callerName = fullName.isEmpty ? "Telegram user" : fullName
        }
    }

    private func finish(disconnected: Bool) {
        ServiceSoundManager.shared.stopIncomingCallTone()
        guard let call else {
            reset()
            return
        }
        phase = .ending
        let duration = connectedAt.map { max(0, Int(Foundation.Date().timeIntervalSince($0))) } ?? 0
        Task {
            do {
                _ = try await service.discardCall(
                    callId: call.id,
                    connectionId: 0,
                    duration: duration,
                    inviteLink: "",
                    isDisconnected: disconnected,
                    isVideo: call.isVideo
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            reset()
        }
    }

    private func reset() {
        ServiceSoundManager.shared.stopIncomingCallTone()
        mediaSession?.stop()
        mediaSession = nil
        pendingSignalingData.removeAll()
        call = nil
        connectedAt = nil
        callerName = "Telegram user"
        phase = .incoming
        isPresented = false
        VoIPPushManager.shared.endSystemCall()
    }

    private static let supportedProtocol = CallProtocol(
        libraryVersions: ["2.7.7", "5.0.0", "9.0.0", "12.0.0"],
        maxLayer: 92,
        minLayer: 65,
        udpP2p: true,
        udpReflector: true
    )
}
