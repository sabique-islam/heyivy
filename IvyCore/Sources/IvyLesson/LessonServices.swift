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
        history: [LessonExchange],
        onTokenUsage: (@Sendable (_ inputTokens: Int, _ outputTokens: Int) -> Void)? = nil
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

                    // Claude reports input tokens at the start and output tokens at the end. Only the
                    // eval tool asks for them, to report what a run cost.
                    var inputTokens = 0
                    // The Worker reports a broken stream by ending it early, and a cut connection
                    // can end it the same way, so only Claude's own end event means it's all here.
                    var hasReceivedMessageStop = false
                    for try await line in responseBytes.lines {
                        guard line.hasPrefix("data: "),
                              let eventData = line.dropFirst(6).data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else { continue }
                        let eventType = event["type"] as? String
                        if eventType == "message_start",
                           let message = event["message"] as? [String: Any],
                           let usage = message["usage"] as? [String: Any] {
                            inputTokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
                        }
                        if eventType == "message_delta",
                           let usage = event["usage"] as? [String: Any],
                           let outputTokens = usage["output_tokens"] as? Int {
                            onTokenUsage?(inputTokens, outputTokens)
                        }
                        if eventType == "content_block_delta",
                           let delta = event["delta"] as? [String: Any],
                           delta["type"] as? String == "text_delta",
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        } else if eventType == "error" {
                            throw LessonFailureError(failure: .answerFailed)
                        } else if eventType == "message_stop" {
                            hasReceivedMessageStop = true
                        }
                    }
                    guard hasReceivedMessageStop else { throw LessonFailureError(failure: .answerFailed) }
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

    static func failure(forStatusCode statusCode: Int, errorBody: String) -> LessonFailure {
        if statusCode == 504 { return .answerTimedOut }
        return WorkerRefusal.failure(forStatusCode: statusCode, errorBody: errorBody) ?? .answerFailed
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

    /// Attached once the lesson runs. Starting audio output while the mic is starting
    /// breaks the mic on Bluetooth headsets, which switch modes when the mic turns on.
    private var speechPlayer: StreamingSpeechPlayer?
    /// Audio that arrived before the player was attached, played as soon as it is.
    private var audioWaitingForPlayer: [Data] = []
    private let webSocketTask: URLSessionWebSocketTask
    private var receivedAudioSeconds = 0.0
    private var isClosedOnPurpose = false
    private var hasFailed = false

    /// A WebSocket that goes quiet, as when the network drops, reports nothing for minutes, so
    /// the voice is given a deadline instead. Once the voice has been asked to speak, by a
    /// flush or the end of the text, it has this long to send something, and after the end of
    /// the text it has this long between messages until it's done. ElevenLabs usually replies
    /// in under a second and sends faster than it plays, so a gap this long means it's stuck.
    public static let longestSilenceFromVoiceSeconds = 8.0
    private var waitingForVoiceSinceHostSeconds: Double?
    private var hasSentEndOfText = false
    private var silenceCheckTimer: Timer?

    // The Worker closes with these when a device hits its limits.
    private static let spendLimitCloseCode = 4429

    public init(workerBaseURL: String, deviceToken: String) {
        // http:// is only for a local test Worker, like scripts/fake-worker.mjs.
        let webSocketBaseURL = workerBaseURL.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
        var request = URLRequest(url: URL(string: "\(webSocketBaseURL)/voice")!)
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask.maximumMessageSize = 16 * 1024 * 1024
    }

    public func attach(speechPlayer: StreamingSpeechPlayer) {
        self.speechPlayer = speechPlayer
        for waitingAudio in audioWaitingForPlayer { speechPlayer.enqueue(pcm16Data: waitingAudio) }
        audioWaitingForPlayer = []
        if hasReceivedFinalMessage { speechPlayer.markStreamEnded() }
    }

    /// Open this when the key goes down. Connecting takes about 250 ms, which is then off
    /// the critical path. By default ElevenLabs waits for about 120 characters before
    /// speaking, so a short first block keeps the first audio quick.
    public func open() {
        webSocketTask.resume()
        sendMessage(["text": " ", "generation_config": ["chunk_length_schedule": [50]]])
        receiveNextMessage()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.failIfTheVoiceHasGoneQuiet() }
        }
        // Common modes keep it running while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        silenceCheckTimer = timer
    }

    /// A piece that ends a sentence is flushed, so speech starts at the first sentence break.
    public func send(speechText: String) {
        guard !speechText.isEmpty else { return }
        let endsASentence = speechText.range(of: "[.!?](\\s|$)", options: .regularExpression) != nil
        sendMessage(endsASentence ? ["text": speechText, "flush": true] : ["text": speechText])
        if endsASentence { startWaitingForVoiceIfNotAlready() }
    }

    /// Tells the voice no more text is coming, so it speaks the rest and finishes.
    public func finishText() {
        sendMessage(["text": ""])
        hasSentEndOfText = true
        startWaitingForVoiceIfNotAlready()
    }

    public func close() {
        isClosedOnPurpose = true
        stopCheckingForSilence()
        webSocketTask.cancel(with: .normalClosure, reason: nil)
    }

    private func startWaitingForVoiceIfNotAlready() {
        if waitingForVoiceSinceHostSeconds == nil { waitingForVoiceSinceHostSeconds = currentHostSeconds() }
    }

    private func failIfTheVoiceHasGoneQuiet() {
        guard let waitingSince = waitingForVoiceSinceHostSeconds,
              currentHostSeconds() - waitingSince > Self.longestSilenceFromVoiceSeconds else { return }
        reportFailure(.voiceFailed)
        close()
    }

    private func stopCheckingForSilence() {
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil
    }

    /// The connection can fail and time out at once, so this makes sure the lesson hears once.
    private func reportFailure(_ failure: LessonFailure) {
        guard !hasFailed, !isClosedOnPurpose, !hasReceivedFinalMessage else { return }
        hasFailed = true
        stopCheckingForSilence()
        speechPlayer?.markStreamEnded()
        onFailed?(failure)
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
                    let failure: LessonFailure = self.webSocketTask.closeCode.rawValue == Self.spendLimitCloseCode ? .spendLimitReached : .voiceFailed
                    self.reportFailure(failure)
                }
            }
        }
    }

    private func apply(_ message: [String: Any]) {
        // Any reply answers the wait, but after the end of the text the rest is still owed.
        waitingForVoiceSinceHostSeconds = hasSentEndOfText ? currentHostSeconds() : nil
        var audioSecondsInThisMessage = 0.0
        if let audioBase64 = message["audio"] as? String, let audioData = Data(base64Encoded: audioBase64), !audioData.isEmpty {
            if receivedAudioSeconds == 0 { onFirstAudioReceived?() }
            audioSecondsInThisMessage = Double(audioData.count / 2) / StreamingSpeechPlayer.sampleRate
            if let speechPlayer {
                speechPlayer.enqueue(pcm16Data: audioData)
            } else {
                audioWaitingForPlayer.append(audioData)
            }
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
            speechPlayer?.markStreamEnded()
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
