import Foundation
import WebKit

/// The WebSockets of extensions' service workers, opened by Nuri: one opened by the worker itself
/// ends the worker at once in WebKit (Claude's bridge to Claude Desktop and claude.ai). The shim's
/// WebSocket asks Nuri to open, send and close (runtime.sendNativeMessage); what the server sends
/// goes back to the worker through ExtensionHost.tellBackground, in order. They leave with the
/// Origin Chrome gives the extension, as its other requests do.
@available(macOS 15.4, *)
@MainActor
final class ExtensionSockets: NSObject, URLSessionWebSocketDelegate {
    static let shared = ExtensionSockets()

    private struct Socket {
        let id: String
        let extensionID: String
        let task: URLSessionWebSocketTask
        var closed = false
    }

    private var sockets: [String: Socket] = [:]
    private var byTask: [Int: String] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func handle(_ body: [String: Any], from context: WKWebExtensionContext) -> [String: Any] {
        let extensionID = context.uniqueIdentifier
        if let id = body["open"] as? String {
            guard let address = body["url"] as? String, let url = URL(string: address),
                  ["ws", "wss"].contains(url.scheme?.lowercased()) else { return ["error": "The URL's scheme must be either 'ws' or 'wss'."] }
            var request = URLRequest(url: url)
            request.setValue("chrome-extension://\(extensionID)", forHTTPHeaderField: "Origin")
            let protocols = (body["protocols"] as? [String] ?? []).filter { !$0.isEmpty }
            if !protocols.isEmpty { request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol") }
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = 64 * 1024 * 1024
            sockets[id] = Socket(id: id, extensionID: extensionID, task: task)
            byTask[task.taskIdentifier] = id
            task.resume()
            receive(id)
            return [:]
        }
        if let id = body["send"] as? String {
            guard let socket = sockets[id], socket.extensionID == extensionID, !socket.closed else { return ["error": "WebSocket is not open"] }
            let message: URLSessionWebSocketTask.Message
            if let text = body["text"] as? String { message = .string(text) }
            else if let encoded = body["binary"] as? String, let data = Data(base64Encoded: encoded) { message = .data(data) }
            else { return [:] }
            socket.task.send(message) { _ in }
            return [:]
        }
        if let id = body["close"] as? String {
            guard let socket = sockets[id], socket.extensionID == extensionID else { return [:] }
            let code = URLSessionWebSocketTask.CloseCode(rawValue: (body["code"] as? NSNumber)?.intValue ?? 1000) ?? .normalClosure
            socket.task.cancel(with: code, reason: (body["reason"] as? String)?.data(using: .utf8))
            return [:]
        }
        return [:]
    }

    /// An extension going away, or its worker no longer knowing the socket.
    func closeAll(of extensionID: String) {
        for socket in sockets.values where socket.extensionID == extensionID { forget(socket.id, cancel: true) }
    }

    private func forget(_ id: String, cancel: Bool) {
        guard let socket = sockets.removeValue(forKey: id) else { return }
        byTask[socket.task.taskIdentifier] = nil
        if cancel { socket.task.cancel(with: .goingAway, reason: nil) }
    }

    private func receive(_ id: String) {
        guard let task = sockets[id]?.task else { return }
        task.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.sockets[id] != nil else { return }
                guard case .success(let message) = result else { return }
                switch message {
                case .string(let text): self.tell(id, ["type": "message", "text": text])
                case .data(let data): self.tell(id, ["type": "message", "binary": data.base64EncodedString()])
                @unknown default: break
                }
                self.receive(id)
            }
        }
    }

    /// To the worker. One that no longer knows the socket (WebKit reloaded it) has it closed.
    private func tell(_ id: String, _ event: [String: Any]) {
        guard let socket = sockets[id] else { return }
        var event = event
        event["id"] = id
        ExtensionHost.shared.tellBackground(socket.extensionID, ["nuriSocket": event]) { [weak self] known in
            if !known, event["type"] as? String != "close" { self?.forget(id, cancel: true) }
        }
    }

    private func closed(_ id: String, code: Int, reason: String, error: Bool) {
        guard var socket = sockets[id], !socket.closed else { return }
        socket.closed = true
        sockets[id] = socket
        tell(id, ["type": "close", "code": code, "reason": reason, "wasClean": !error, "error": error])
        forget(id, cancel: false)
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol chosen: String?) {
        let task = webSocketTask.taskIdentifier
        MainActor.assumeIsolated {
            guard let id = byTask[task] else { return }
            tell(id, ["type": "open", "protocol": chosen ?? ""])
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let task = webSocketTask.taskIdentifier
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        MainActor.assumeIsolated {
            guard let id = byTask[task] else { return }
            closed(id, code: closeCode.rawValue, reason: text, error: false)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let identifier = task.taskIdentifier
        MainActor.assumeIsolated {
            guard let id = byTask[identifier] else { return }
            closed(id, code: 1006, reason: "", error: error != nil)
        }
    }
}
