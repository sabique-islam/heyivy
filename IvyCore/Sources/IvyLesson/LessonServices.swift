import Foundation
import IvyCore

/// A lesson failure the state machine knows how to explain.
public struct LessonFailureError: Error, Equatable {
    public let failure: LessonFailure
}

/// One past exchange, sent so follow-up questions make sense.
public struct LessonExchange: Sendable {
    public var question: String
    public var spokenAnswer: String

    public init(question: String, spokenAnswer: String) {
        self.question = question
        self.spokenAnswer = spokenAnswer
    }
}

/// Streams Claude's script from the Worker's `/chat`, as text pieces in order.
public enum ClaudeScriptStream {
    public static func streamScript(
        workerBaseURL: String,
        deviceToken: String,
        systemPrompt: String,
        screenshotJPEGData: Data,
        screenshotLabel: String,
        question: String,
        history: [LessonExchange]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let streamTask = Task {
                do {
                    var request = URLRequest(url: URL(string: "\(workerBaseURL)/chat")!)
                    request.httpMethod = "POST"
                    // Time allowed between bytes. Claude sends pings, so silence this long means it's stuck.
                    request.timeoutInterval = 30
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")

                    var messages: [[String: Any]] = []
                    for exchange in history {
                        messages.append(["role": "user", "content": exchange.question])
                        messages.append(["role": "assistant", "content": exchange.spokenAnswer])
                    }
                    messages.append(["role": "user", "content": [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": screenshotJPEGData.base64EncodedString()]],
                        ["type": "text", "text": screenshotLabel],
                        ["type": "text", "text": question],
                    ]])
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["system": systemPrompt, "messages": messages, "stream": true])

                    let (responseBytes, response) = try await URLSession.shared.bytes(for: request)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard statusCode == 200 else {
                        var errorBody = ""
                        for try await line in responseBytes.lines where errorBody.count < 2000 { errorBody += line }
                        throw LessonFailureError(failure: failure(forStatusCode: statusCode, errorBody: errorBody))
                    }

                    for try await line in responseBytes.lines {
                        guard line.hasPrefix("data: "),
                              let eventData = line.dropFirst(6).data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else { continue }
                        let eventType = event["type"] as? String
                        if eventType == "content_block_delta",
                           let delta = event["delta"] as? [String: Any],
                           delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        } else if eventType == "error" {
                            throw LessonFailureError(failure: .answerFailed)
                        }
                    }
                    continuation.finish()
                } catch let urlError as URLError {
                    switch urlError.code {
                    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed:
                        continuation.finish(throwing: LessonFailureError(failure: .offline))
                    case .timedOut:
                        continuation.finish(throwing: LessonFailureError(failure: .answerTimedOut))
                    case .cancelled:
                        continuation.finish(throwing: CancellationError())
                    default:
                        continuation.finish(throwing: LessonFailureError(failure: .answerFailed))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in streamTask.cancel() }
        }
    }

    /// The Worker's error shape is `{"error":{"code": ...}}`, so the code says which 429 it is.
    static func failure(forStatusCode statusCode: Int, errorBody: String) -> LessonFailure {
        switch statusCode {
        case 401: return .notAuthorized
        case 429: return errorBody.contains("spend_limit_reached") ? .spendLimitReached : .rateLimited
        case 504: return .answerTimedOut
        default: return .answerFailed
        }
    }
}

/// One lesson's speech over the Worker's `/voice` WebSocket. Text goes in as Claude writes
/// it, audio comes back into the player, and character timings build the speech timeline.
@MainActor
public final class VoiceStream {
    public private(set) var speechTimeline = SpeechTimeline()
    public private(set) var hasReceivedFinalMessage = false
    public var onFirstAudioReceived: (() -> Void)?
    /// Called if the connection ends before the voice finished, with no retry.
    public var onFailed: ((LessonFailure) -> Void)?

    private let speechPlayer: StreamingSpeechPlayer
    private let webSocketTask: URLSessionWebSocketTask
    private var receivedAudioSeconds = 0.0
    private var isClosedOnPurpose = false

    // The Worker closes with these when a device hits its limits.
    private static let spendLimitCloseCode = 4429

    public init(workerBaseURL: String, deviceToken: String, speechPlayer: StreamingSpeechPlayer) {
        self.speechPlayer = speechPlayer
        var request = URLRequest(url: URL(string: "\(workerBaseURL.replacingOccurrences(of: "https://", with: "wss://"))/voice")!)
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask.maximumMessageSize = 16 * 1024 * 1024
    }

    /// Open this when the key goes down. Connecting takes about 250 ms, which is then off
    /// the critical path. By default ElevenLabs waits for about 120 characters before
    /// speaking, so a short first block keeps the first audio quick.
    public func open() {
        webSocketTask.resume()
        sendMessage(["text": " ", "generation_config": ["chunk_length_schedule": [50]]])
        receiveNextMessage()
    }

    /// A piece that ends a sentence is flushed, so speech starts at the first sentence break.
    public func send(speechText: String) {
        guard !speechText.isEmpty else { return }
        let endsASentence = speechText.range(of: "[.!?](\\s|$)", options: .regularExpression) != nil
        sendMessage(endsASentence ? ["text": speechText, "flush": true] : ["text": speechText])
    }

    /// Tells the voice no more text is coming, so it speaks the rest and finishes.
    public func finishText() {
        sendMessage(["text": ""])
    }

    public func close() {
        isClosedOnPurpose = true
        webSocketTask.cancel(with: .normalClosure, reason: nil)
    }

    private func sendMessage(_ message: [String: Any]) {
        guard let messageData = try? JSONSerialization.data(withJSONObject: message),
              let messageText = String(data: messageData, encoding: .utf8) else { return }
        webSocketTask.send(.string(messageText)) { _ in }
    }

    private func receiveNextMessage() {
        webSocketTask.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.string(let messageText)):
                    if let messageData = messageText.data(using: .utf8),
                       let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] {
                        self.apply(message)
                    }
                    self.receiveNextMessage()
                case .success:
                    self.receiveNextMessage()
                case .failure:
                    guard !self.isClosedOnPurpose, !self.hasReceivedFinalMessage else { return }
                    self.speechPlayer.markStreamEnded()
                    let failure: LessonFailure = self.webSocketTask.closeCode.rawValue == Self.spendLimitCloseCode ? .spendLimitReached : .voiceFailed
                    self.onFailed?(failure)
                }
            }
        }
    }

    private func apply(_ message: [String: Any]) {
        var audioSecondsInThisMessage = 0.0
        if let audioBase64 = message["audio"] as? String, let audioData = Data(base64Encoded: audioBase64), !audioData.isEmpty {
            if receivedAudioSeconds == 0 { onFirstAudioReceived?() }
            audioSecondsInThisMessage = Double(audioData.count / 2) / StreamingSpeechPlayer.sampleRate
            speechPlayer.enqueue(pcm16Data: audioData)
        }
        // The alignment describes this message's own audio, so it comes after the audio before it.
        if let alignment = message["alignment"] as? [String: Any],
           let characters = alignment["chars"] as? [String],
           let startTimes = alignment["charStartTimesMs"] as? [NSNumber],
           let durations = alignment["charDurationsMs"] as? [NSNumber] {
            speechTimeline.appendChunk(
                AlignedSpeechChunk(characters: characters, characterStartTimesMilliseconds: startTimes.map(\.doubleValue), characterDurationsMilliseconds: durations.map(\.doubleValue)),
                audioSecondsBeforeChunk: receivedAudioSeconds
            )
        }
        receivedAudioSeconds += audioSecondsInThisMessage
        if message["isFinal"] as? Bool == true {
            hasReceivedFinalMessage = true
            speechTimeline.finishStream()
            speechPlayer.markStreamEnded()
            close()
        }
    }
}

/// Times every stage of a lesson from the moment the key was released, and never records
/// what was said or shown. One line per lesson, for comparing runs.
public final class LessonTimingLog {
    private let startHostSeconds: Double
    public private(set) var stageTimesMilliseconds: [(stage: String, milliseconds: Int)] = []

    public init(startHostSeconds: Double = currentHostSeconds()) {
        self.startHostSeconds = startHostSeconds
    }

    public func record(_ stage: String) {
        stageTimesMilliseconds.append((stage, Int(((currentHostSeconds() - startHostSeconds) * 1000).rounded())))
    }

    public func millisecondsSinceStart() -> Int {
        Int(((currentHostSeconds() - startHostSeconds) * 1000).rounded())
    }

    public var summaryLine: String {
        "lesson timing: " + stageTimesMilliseconds.map { "\($0.stage) \($0.milliseconds)ms" }.joined(separator: " | ")
    }
}
