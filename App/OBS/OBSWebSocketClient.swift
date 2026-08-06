//
//  OBSWebSocketClient.swift
//  Greenroom
//
//  Minimal obs-websocket v5 client: connects, performs the Hello/Identify
//  handshake (including SHA256 challenge-response auth if a password is
//  set), and sends typed requests, matching responses back to requests by
//  requestId. This implements exactly the documented obs-websocket v5
//  protocol (op codes, message shapes, auth algorithm) - see
//  https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md
//
import Foundation
import CryptoKit

final class OBSWebSocketClient: NSObject {

    struct RequestError: Error, LocalizedError {
        let code: Int
        let comment: String?
        var errorDescription: String? { comment ?? "OBS request failed (code \(code))" }
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var password = ""

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private let lock = NSLock()

    /// Connects, performs the handshake, and returns once obs-websocket has
    /// confirmed authentication ("Identified"). Throws if the socket can't
    /// be opened (e.g. OBS isn't up yet) or auth is rejected.
    func connect(port: Int, password: String) async throws {
        self.password = password
        let session = URLSession(configuration: .default)
        urlSession = session

        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { throw URLError(.badURL) }
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        listen()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.readyContinuation = continuation
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    /// obs-websocket's documented code for "the server is not ready to
    /// handle the request" - happens right after connecting, while OBS is
    /// still finishing loading its scene collection. Their own docs say to
    /// just retry after a delay, so `request` does that transparently.
    private static let notReadyCode = 207

    /// Sends a request and awaits its matching RequestResponse's `responseData`.
    @discardableResult
    func request(_ type: String, data: [String: Any] = [:], notReadyRetries: Int = 8) async throws -> [String: Any] {
        for attempt in 0...notReadyRetries {
            do {
                return try await sendRequest(type, data: data)
            } catch let error as RequestError where error.code == Self.notReadyCode {
                if attempt == notReadyRetries { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        fatalError("unreachable") // loop always returns or throws above
    }

    private func sendRequest(_ type: String, data: [String: Any]) async throws -> [String: Any] {
        let requestId = UUID().uuidString
        let message: [String: Any] = [
            "op": 6,
            "d": [
                "requestType": type,
                "requestId": requestId,
                "requestData": data
            ] as [String: Any]
        ]
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingRequests[requestId] = continuation
            lock.unlock()
            send(message)
        }
    }

    // MARK: - Wire handling

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.failAllPending(with: error)
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.handle(json)
                }
                self.listen()
            }
        }
    }

    private func handle(_ json: [String: Any]) {
        guard let op = json["op"] as? Int, let d = json["d"] as? [String: Any] else { return }
        switch op {
        case 0: handleHello(d)              // Hello
        case 2:                              // Identified
            readyContinuation?.resume()
            readyContinuation = nil
        case 7: handleRequestResponse(d)     // RequestResponse
        default: break
        }
    }

    private func handleHello(_ hello: [String: Any]) {
        var identify: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": 0]
        if let auth = hello["authentication"] as? [String: Any],
           let challenge = auth["challenge"] as? String,
           let salt = auth["salt"] as? String {
            identify["authentication"] = Self.authenticationString(password: password, salt: salt, challenge: challenge)
        }
        send(["op": 1, "d": identify])
    }

    private func handleRequestResponse(_ d: [String: Any]) {
        guard let requestId = d["requestId"] as? String else { return }
        lock.lock()
        let continuation = pendingRequests.removeValue(forKey: requestId)
        lock.unlock()
        guard let continuation else { return }

        let status = d["requestStatus"] as? [String: Any]
        if (status?["result"] as? Bool) == true {
            continuation.resume(returning: (d["responseData"] as? [String: Any]) ?? [:])
        } else {
            let code = (status?["code"] as? Int) ?? -1
            continuation.resume(throwing: RequestError(code: code, comment: status?["comment"] as? String))
        }
    }

    private func failAllPending(with error: Error) {
        lock.lock()
        let all = pendingRequests
        pendingRequests.removeAll()
        lock.unlock()
        all.values.forEach { $0.resume(throwing: error) }

        if let readyContinuation {
            readyContinuation.resume(throwing: error)
            self.readyContinuation = nil
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }

    // MARK: - Auth (obs-websocket v5's documented SHA256 challenge-response)

    private static func authenticationString(password: String, salt: String, challenge: String) -> String {
        let secret = SHA256.hash(data: Data((password + salt).utf8))
        let secretBase64 = Data(secret).base64EncodedString()
        let authHash = SHA256.hash(data: Data((secretBase64 + challenge).utf8))
        return Data(authHash).base64EncodedString()
    }
}
