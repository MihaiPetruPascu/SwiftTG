// TelegramSession.swift

import Combine
import Foundation
import TDLibKit

// MARK: - TelegramSessionConfiguration

struct TelegramSessionConfiguration: Sendable {
    let apiHash: String
    let apiId: Int
    let applicationVersion: String
    let databaseDirectory: String
    let deviceModel: String
    let systemLanguageCode: String
    let systemVersion: String
}

// MARK: - TelegramSession

final class TelegramSession: @unchecked Sendable {
    // MARK: Lifecycle

    init() {
        _ = internalClient
    }

    // MARK: Internal

    var client: TDLibClient { internalClient }

    var authorizationStatePublisher: AnyPublisher<AuthorizationState, Never> {
        updateStore.authorizationStatePublisher
    }

    var chatListPublisher: AnyPublisher<ChatListSnapshot, Never> {
        updateStore.chatListPublisher
    }

    var updatePublisher: AnyPublisher<Update, Never> {
        updateStore.updatePublisher
    }

    func filePublisher(fileId: Int) -> AnyPublisher<File, Never> {
        updateStore.filePublisher(fileId: fileId)
    }

    func messagePublisher(chatId: Int64) -> AnyPublisher<TelegramMessageSnapshot, Never> {
        updateStore.messagePublisher(chatId: chatId)
    }

    func mergeMessageHistory(chatId: Int64, messages: [Message]) {
        updateStore.mergeMessageHistory(chatId: chatId, messages: messages)
    }

    func replaceMessageHistory(chatId: Int64, messages: [Message]) {
        updateStore.replaceMessageHistory(chatId: chatId, messages: messages)
    }

    func mergeMessages(chatId: Int64, messages: [Message]) {
        updateStore.mergeMessages(chatId: chatId, messages: messages)
    }

    func notifyMessageContentChanged(chatId: Int64, messageId: Int64, newContent: MessageContent) {
        updateStore.publish(.updateMessageContent(UpdateMessageContent(
            chatId: chatId,
            messageId: messageId,
            newContent: newContent,
        )))
    }

    func mergeChatListChats(_ chats: [Chat]) {
        updateStore.mergeChatListChats(chats)
    }

    func mergeInitialFile(_ file: File) {
        updateStore.mergeInitialFile(file)
    }

    func start(configuration: TelegramSessionConfiguration) {
        stateLock.lock()
        self.configuration = configuration
        stateLock.unlock()

        try? client.setLogStream(logStream: .logStreamEmpty) { _ in }
        configureIfReady()
    }

    func close() {
        manager.closeClients()
    }

    // MARK: Private

    private lazy var internalClient: TDLibClient = manager.createClient { [weak self] data, client in
        guard let self else { return }
        do {
            let update = try client.decoder.decode(Update.self, from: normalizedUpdateData(data))
            process(update)
        } catch {
            print("TDLib update decoding failed: \(error)")
        }
    }

    private var configuration: TelegramSessionConfiguration?
    private var isConfiguringParameters = false
    private var isWaitingForParameters = false
    private var hasEnabledIncomingCalls = false
    private let manager = TDLibClientManager()
    private let stateLock = NSLock()
    private let updateStore = TelegramUpdateStore()

    private func process(_ update: Update) {
        if case .updateAuthorizationState(let value) = update {
            if case .authorizationStateWaitTdlibParameters = value.authorizationState {
                stateLock.lock()
                isWaitingForParameters = true
                stateLock.unlock()
                configureIfReady()
            } else if case .authorizationStateReady = value.authorizationState {
                enableIncomingCallsIfNeeded()
            }
        }
        updateStore.publish(update)
    }

    private func enableIncomingCallsIfNeeded() {
        stateLock.lock()
        guard !hasEnabledIncomingCalls else {
            stateLock.unlock()
            return
        }
        hasEnabledIncomingCalls = true
        stateLock.unlock()

        Task { [weak self, client] in
            do {
                let sessions = try await client.getActiveSessions()
                guard let current = sessions.sessions.first(where: \.isCurrent) else {
                    self?.resetIncomingCallsAttempt()
                    return
                }
                if !current.canAcceptCalls {
                    _ = try await client.toggleSessionCanAcceptCalls(
                        canAcceptCalls: true,
                        sessionId: current.id
                    )
                }
            } catch {
                self?.resetIncomingCallsAttempt()
                print("Enabling incoming Telegram calls failed: \(error)")
            }
        }
    }

    private func configureIfReady() {
        stateLock.lock()
        guard isWaitingForParameters,
              !isConfiguringParameters,
              let configuration
        else {
            stateLock.unlock()
            return
        }
        isConfiguringParameters = true
        stateLock.unlock()

        Task { [weak self, client] in
            do {
                try await client.setTdlibParameters(
                    apiHash: configuration.apiHash,
                    apiId: configuration.apiId,
                    applicationVersion: configuration.applicationVersion,
                    databaseDirectory: configuration.databaseDirectory,
                    databaseEncryptionKey: Data(),
                    deviceModel: configuration.deviceModel,
                    filesDirectory: configuration.databaseDirectory,
                    systemLanguageCode: configuration.systemLanguageCode,
                    systemVersion: configuration.systemVersion,
                    useChatInfoDatabase: true,
                    useFileDatabase: true,
                    useMessageDatabase: true,
                    useSecretChats: true,
                    useTestDc: false,
                )
            } catch {
                self?.resetConfigurationAttempt()
                print("TDLib configuration failed: \(error)")
            }
        }
    }

    private func resetConfigurationAttempt() {
        stateLock.lock()
        isConfiguringParameters = false
        stateLock.unlock()
    }

    private func resetIncomingCallsAttempt() {
        stateLock.lock()
        hasEnabledIncomingCalls = false
        stateLock.unlock()
    }

    private func normalizedUpdateData(_ data: Data) -> Data {
        guard let json = String(data: data, encoding: .utf8),
              json.contains("\"allow_p2p\"") || json.contains("\"udp_p2p\"")
        else {
            return data
        }
        // JSONDecoder.convertFromSnakeCase preserves a capitalized trailing
        // acronym (P2P), while TDLibKit generates properties ending in `P2p`.
        let normalized = json
            .replacingOccurrences(of: "\"allow_p2p\"", with: "\"allowP2p\"")
            .replacingOccurrences(of: "\"udp_p2p\"", with: "\"udpP2p\"")
        return Data(normalized.utf8)
    }

}
