import CallKit
import PushKit

private struct VoIPUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

final class VoIPPushManager: NSObject, PKPushRegistryDelegate, @unchecked Sendable {
    static let shared = VoIPPushManager()

    override init() {
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        provider.setDelegate(self, queue: nil)
    }

    func pushRegistry(
        _: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = pushCredentials.token
        Task { @MainActor in
            PushNotificationsManager.shared.didRegisterVoIP(deviceToken: token)
        }
    }

    func endSystemCall() {
        guard let uuid = pendingCallUUID else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        pendingCallUUID = nil
    }

    func pushRegistry(_: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
    }

    func pushRegistry(
        _: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        let uuid = UUID()
        pendingCallUUID = uuid
        let update = CXCallUpdate()
        update.localizedCallerName = callerName(from: payload.dictionaryPayload)
        update.hasVideo = payload.dictionaryPayload["video"] as? Bool ?? false
        let userInfo = VoIPUncheckedSendable(value: payload.dictionaryPayload)
        let pushCompletion = VoIPUncheckedSendable(value: completion)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
            Task { @MainActor in
                _ = await PushNotificationsManager.shared.process(userInfo: userInfo.value)
                pushCompletion.value()
                self?.scheduleCallKitCleanup(uuid: uuid)
            }
        }
    }

    private let registry = PKPushRegistry(queue: .main)
    private let provider: CXProvider = {
        let configuration = CXProviderConfiguration(localizedName: "BetterTG")
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        return CXProvider(configuration: configuration)
    }()
    private var pendingCallUUID: UUID?

    private func callerName(from payload: [AnyHashable: Any]) -> String {
        if let aps = payload["aps"] as? [String: Any],
           let alert = aps["alert"] as? [String: Any],
           let arguments = alert["loc-args"] as? [String],
           let first = arguments.first,
           !first.isEmpty
        {
            return first
        }
        return "Telegram call"
    }

    private func scheduleCallKitCleanup(uuid: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard self?.pendingCallUUID == uuid else { return }
            self?.provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
            self?.pendingCallUUID = nil
        }
    }
}

extension VoIPPushManager: CXProviderDelegate {
    func providerDidReset(_: CXProvider) {
        pendingCallUUID = nil
    }

    func provider(_: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
        Task { @MainActor in
            IncomingCallCoordinator.shared.accept()
        }
        pendingCallUUID = nil
    }

    func provider(_: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        Task { @MainActor in
            if IncomingCallCoordinator.shared.isPresented {
                IncomingCallCoordinator.shared.decline()
            }
        }
        pendingCallUUID = nil
    }
}
