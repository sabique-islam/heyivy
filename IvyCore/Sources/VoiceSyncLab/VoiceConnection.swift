import Foundation

/// Reads the device token the same way `scripts/mint-device-token.mjs` stored it. Going
/// through the `security` tool, which created the Keychain item, avoids a permission prompt.
func readWorkerDeviceToken() -> String? {
    let securityProcess = Process()
    securityProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    securityProcess.arguments = ["find-generic-password", "-s", "me.ivyx.ivy.worker-device-token", "-a", "device", "-w"]
    let outputPipe = Pipe()
    securityProcess.standardOutput = outputPipe
    securityProcess.standardError = FileHandle.nullDevice
    do { try securityProcess.run() } catch { return nil }
    securityProcess.waitUntilExit()
    guard securityProcess.terminationStatus == 0 else { return nil }
    let tokenData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// One lesson's speech over the Worker's `/voice` WebSocket. Messages are handed back on
/// the main thread, in order.
final class VoiceConnection {
    private let webSocketTask: URLSessionWebSocketTask
    private var onMessage: (([String: Any]) -> Void)?
    private var onClose: ((String) -> Void)?

    init(workerBaseURL: String, deviceToken: String) {
        var request = URLRequest(url: URL(string: "\(workerBaseURL.replacingOccurrences(of: "https://", with: "wss://"))/voice")!)
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask.maximumMessageSize = 16 * 1024 * 1024
    }

    func open(onMessage: @escaping ([String: Any]) -> Void, onClose: @escaping (String) -> Void) {
        self.onMessage = onMessage
        self.onClose = onClose
        webSocketTask.resume()
        receiveNextMessage()
    }

    func send(_ message: [String: Any]) {
        guard let messageData = try? JSONSerialization.data(withJSONObject: message),
              let messageText = String(data: messageData, encoding: .utf8) else { return }
        webSocketTask.send(.string(messageText)) { _ in }
    }

    func close() {
        webSocketTask.cancel(with: .normalClosure, reason: nil)
    }

    private func receiveNextMessage() {
        webSocketTask.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(.string(let messageText)):
                    if let messageData = messageText.data(using: .utf8),
                       let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] {
                        self.onMessage?(message)
                    }
                    self.receiveNextMessage()
                case .success:
                    self.receiveNextMessage()
                case .failure(let error):
                    self.onClose?("closed: \(error.localizedDescription) (code \(self.webSocketTask.closeCode.rawValue))")
                }
            }
        }
    }
}
