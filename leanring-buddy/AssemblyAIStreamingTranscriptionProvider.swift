//
//  AssemblyAIStreamingTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming AI transcription provider backed by AssemblyAI's websocket API.
//

import AVFoundation
import Foundation
import Network

struct AssemblyAIStreamingTranscriptionProviderError: LocalizedError {
    let message: String
    /// Set when the Worker refused the token request, so the app can say why.
    var workerStatusCode: Int? = nil
    var workerErrorBody: String = ""

    var errorDescription: String? {
        message
    }
}

final class AssemblyAIStreamingTranscriptionProvider: BuddyTranscriptionProvider {
    /// URL for the Cloudflare Worker endpoint that returns a short-lived
    /// AssemblyAI streaming token. The real API key never leaves the server.
    private static let tokenProxyURL = "https://secrets.worker.ivy.ivyx.me/transcribe-token"

    let displayName = "AssemblyAI"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        // Fetch a fresh temporary token from the proxy before each session
        let temporaryToken = try await fetchTemporaryToken()
        // Tokens are never logged, not even part of one.
        print("🎙️ AssemblyAI: fetched temporary token")

        let session = AssemblyAIStreamingTranscriptionSession(
            apiKey: nil,
            temporaryToken: temporaryToken,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }

    /// Calls the Cloudflare Worker to get a short-lived AssemblyAI token.
    private func fetchTemporaryToken() async throws -> String {
        var request = URLRequest(url: URL(string: Self.tokenProxyURL)!)
        request.httpMethod = "POST"
        WorkerDeviceToken.addAuthorizationHeader(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "Failed to fetch AssemblyAI token (HTTP \(statusCode)): \(body)",
                workerStatusCode: statusCode,
                workerErrorBody: body
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "Invalid token response from proxy."
            )
        }

        return token
    }
}

private final class AssemblyAIStreamingTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    private struct MessageEnvelope: Decodable {
        let type: String
    }

    private struct TurnMessage: Decodable {
        let type: String
        let transcript: String?
        let turn_order: Int?
        let end_of_turn: Bool?
        let turn_is_formatted: Bool?
    }

    private struct ErrorMessage: Decodable {
        let type: String
        let error: String?
        let message: String?
    }

    private struct StoredTurnTranscript {
        var transcriptText: String
        var isFormatted: Bool
    }

    private static let websocketBaseURLString = "wss://streaming.assemblyai.com/v3/ws"
    private static let targetSampleRate = 16_000.0
    private static let explicitFinalTranscriptGracePeriodSeconds = 1.4

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.8

    private let apiKey: String?
    private let temporaryToken: String?
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.assemblyai.state")
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.assemblyai.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)
    /// Where the connection's callbacks run.
    private let connectionQueue = DispatchQueue(label: "com.learningbuddy.assemblyai.connection")

    /// Network framework rather than URLSessionWebSocketTask, because URLSession never frees a
    /// finished WebSocket task, so each question left one behind with its connection and
    /// certificates (drawing plan, D7). Each session has its own connection, which is
    /// cancelled when the session ends.
    private var connection: NWConnection?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var hasResolvedReadyContinuation = false
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false
    private var latestTranscriptText = ""
    private var activeTurnOrder: Int?
    private var activeTurnTranscriptText = ""
    private var storedTurnTranscriptsByOrder: [Int: StoredTurnTranscript] = [:]
    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?

    init(
        apiKey: String?,
        temporaryToken: String?,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.apiKey = apiKey
        self.temporaryToken = temporaryToken
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        let websocketURL = try Self.makeWebsocketURL(
            temporaryToken: temporaryToken,
            keyterms: keyterms
        )

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        if let apiKey {
            webSocketOptions.setAdditionalHeaders([("Authorization", apiKey)])
        }
        let connectionParameters = NWParameters.tls
        connectionParameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        let connection = NWConnection(to: .url(websocketURL), using: connectionParameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] connectionState in
            switch connectionState {
            // Waiting means there's no route, as when offline, and it would wait indefinitely.
            case .failed(let connectionError), .waiting(let connectionError):
                // This handler can run on any thread, so it hands the failure over. Reporting
                // goes through the state queue either way.
                Task { @MainActor [weak self] in
                    self?.failSession(with: connectionError)
                    self?.endConnection()
                }
            default:
                break
            }
        }
        connection.start(queue: connectionQueue)

        receiveNextMessage()

        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        sendWebSocketMessage(audioPCM16Data, opcode: .binary)
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
        }

        sendJSONMessage(["type": "ForceEndpoint"])
    }

    func cancel() {
        stateQueue.async {
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
        }

        sendJSONMessage(["type": "Terminate"])
        // After the Terminate, on the same queue, so it goes out first.
        sendQueue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            let closeMetadata = NWProtocolWebSocket.Metadata(opcode: .close)
            closeMetadata.closeCode = .protocolCode(.goingAway)
            let closeContext = NWConnection.ContentContext(identifier: "close", metadata: [closeMetadata])
            connection.send(content: nil, contentContext: closeContext, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.endConnection()
            })
        }
    }

    deinit {
        connection?.cancel()
    }

    /// Cancelling is what frees the connection. It's safe to call more than once.
    private func endConnection() {
        connection?.cancel()
    }

    private func receiveNextMessage() {
        connection?.receiveMessage { [weak self] messageData, messageContext, _, receiveError in
            guard let self else { return }

            if let receiveError {
                // Cancelled on purpose, which isn't a failure to report.
                if case .posix(.ECANCELED) = receiveError { return }
                self.failSession(with: receiveError)
                self.endConnection()
                return
            }

            let webSocketMetadata = messageContext?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            // AssemblyAI closes after its Termination message, or on a problem. Either way the
            // session is over, as when URLSession reported the close as a receive failure.
            if webSocketMetadata?.opcode == .close {
                self.failSession(with: AssemblyAIStreamingTranscriptionProviderError(message: "AssemblyAI closed the connection."))
                self.endConnection()
                return
            }

            if let messageData, let text = String(data: messageData, encoding: .utf8) {
                self.handleIncomingTextMessage(text)
            }

            self.receiveNextMessage()
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8) else { return }

        do {
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: messageData)

            switch envelope.type.lowercased() {
            case "begin":
                resolveReadyContinuationIfNeeded(with: .success(()))
            case "turn":
                let turnMessage = try JSONDecoder().decode(TurnMessage.self, from: messageData)
                handleTurnMessage(turnMessage)
            case "termination":
                resolveReadyContinuationIfNeeded(with: .success(()))
                stateQueue.async {
                    if self.isAwaitingExplicitFinalTranscript && !self.hasDeliveredFinalTranscript {
                        self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
                    }
                }
            case "error":
                let errorMessage = try JSONDecoder().decode(ErrorMessage.self, from: messageData)
                let messageText = errorMessage.error ?? errorMessage.message ?? "AssemblyAI returned an error."
                failSession(with: AssemblyAIStreamingTranscriptionProviderError(message: messageText))
            default:
                break
            }
        } catch {
            failSession(with: error)
        }
    }

    private func handleTurnMessage(_ turnMessage: TurnMessage) {
        let transcriptText = turnMessage.transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        stateQueue.async {
            let turnOrder = turnMessage.turn_order
                ?? self.activeTurnOrder
                ?? ((self.storedTurnTranscriptsByOrder.keys.max() ?? -1) + 1)

            if turnMessage.end_of_turn == true || turnMessage.turn_is_formatted == true {
                self.activeTurnOrder = nil
                self.activeTurnTranscriptText = ""
                self.storeTurnTranscript(
                    transcriptText,
                    forTurnOrder: turnOrder,
                    isFormatted: turnMessage.turn_is_formatted == true
                )
            } else {
                self.activeTurnOrder = turnOrder
                self.activeTurnTranscriptText = transcriptText
            }

            let fullTranscriptText = self.composeFullTranscript()
            self.latestTranscriptText = fullTranscriptText

            if !fullTranscriptText.isEmpty {
                self.onTranscriptUpdate(fullTranscriptText)
            }

            guard self.isAwaitingExplicitFinalTranscript else { return }

            if turnMessage.end_of_turn == true || turnMessage.turn_is_formatted == true {
                self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
                self.explicitFinalTranscriptDeadlineWorkItem = nil
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }
    }

    private func storeTurnTranscript(
        _ transcriptText: String,
        forTurnOrder turnOrder: Int,
        isFormatted: Bool
    ) {
        guard !transcriptText.isEmpty else { return }

        if let existingTurnTranscript = storedTurnTranscriptsByOrder[turnOrder] {
            if existingTurnTranscript.isFormatted && !isFormatted {
                return
            }
        }

        storedTurnTranscriptsByOrder[turnOrder] = StoredTurnTranscript(
            transcriptText: transcriptText,
            isFormatted: isFormatted
        )
    }

    private func composeFullTranscript() -> String {
        let committedTranscriptSegments = storedTurnTranscriptsByOrder
            .sorted(by: { $0.key < $1.key })
            .map(\.value.transcriptText)
            .filter { !$0.isEmpty }

        var transcriptSegments = committedTranscriptSegments

        let trimmedActiveTurnTranscriptText = activeTurnTranscriptText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedActiveTurnTranscriptText.isEmpty {
            transcriptSegments.append(trimmedActiveTurnTranscriptText)
        }

        return transcriptSegments.joined(separator: " ")
    }

    private func scheduleExplicitFinalTranscriptDeadline() {
        explicitFinalTranscriptDeadlineWorkItem?.cancel()

        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self else { return }
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }

        explicitFinalTranscriptDeadlineWorkItem = deadlineWorkItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.explicitFinalTranscriptGracePeriodSeconds,
            execute: deadlineWorkItem
        )
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        explicitFinalTranscriptDeadlineWorkItem?.cancel()
        explicitFinalTranscriptDeadlineWorkItem = nil
        onFinalTranscriptReady(transcriptText)
        sendJSONMessage(["type": "Terminate"])
    }

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        sendWebSocketMessage(Data(jsonString.utf8), opcode: .text)
    }

    private func sendWebSocketMessage(_ messageData: Data, opcode: NWProtocolWebSocket.Opcode) {
        sendQueue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            let messageContext = NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
            connection.send(content: messageData, contentContext: messageContext, isComplete: true, completion: .contentProcessed { [weak self] sendError in
                if let sendError {
                    self?.failSession(with: sendError)
                }
            })
        }
    }

    private func failSession(with error: Error) {
        resolveReadyContinuationIfNeeded(with: .failure(error))
        stateQueue.async {
            let latestTranscriptText = self.bestAvailableTranscriptText()

            if self.isAwaitingExplicitFinalTranscript
                && !self.hasDeliveredFinalTranscript
                && !latestTranscriptText.isEmpty {
                print("[AssemblyAI] ⚠️ WebSocket error during active session, delivering partial transcript as fallback: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(latestTranscriptText)
                return
            }
            print("[AssemblyAI] ❌ Session failed with error: \(error.localizedDescription)")

            self.onError(error)
        }
    }

    private func bestAvailableTranscriptText() -> String {
        let composedTranscriptText = composeFullTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !composedTranscriptText.isEmpty {
            return composedTranscriptText
        }

        return latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveReadyContinuationIfNeeded(with result: Result<Void, Error>) {
        stateQueue.async {
            guard !self.hasResolvedReadyContinuation else { return }
            self.hasResolvedReadyContinuation = true

            switch result {
            case .success:
                self.readyContinuation?.resume()
            case .failure(let error):
                self.readyContinuation?.resume(throwing: error)
            }

            self.readyContinuation = nil
        }
    }

    private static func makeWebsocketURL(
        temporaryToken: String?,
        keyterms: [String]
    ) throws -> URL {
        guard var websocketURLComponents = URLComponents(string: websocketBaseURLString) else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "AssemblyAI websocket URL is invalid."
            )
        }

        var queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "format_turns", value: "true"),
            URLQueryItem(name: "speech_model", value: "u3-rt-pro")
        ]

        let normalizedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !normalizedKeyterms.isEmpty,
           let keytermsData = try? JSONSerialization.data(withJSONObject: normalizedKeyterms),
           let keytermsJSONString = String(data: keytermsData, encoding: .utf8) {
            queryItems.append(URLQueryItem(name: "keyterms_prompt", value: keytermsJSONString))
        }

        if let temporaryToken {
            queryItems.append(URLQueryItem(name: "token", value: temporaryToken))
        }

        websocketURLComponents.queryItems = queryItems

        guard let websocketURL = websocketURLComponents.url else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "AssemblyAI websocket URL could not be created."
            )
        }

        return websocketURL
    }
}
