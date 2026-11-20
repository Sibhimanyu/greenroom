//
//  ZoomLoopbackListener.swift
//  Greenroom
//
//  Receives the one HTTP request Zoom's redirect makes, on a plain BSD socket
//  bound to 127.0.0.1 (the same approach as YouTubeAuth's listener; NWListener
//  refuses loopback-only binds). Tries Zoom's registered port first and falls
//  back to a kernel-chosen one. Ends on its own after a timeout, and ends at
//  once when the waiting task is cancelled, so a cancelled sign-in never leaves
//  a port open.
//
import Foundation
import Darwin

final class ZoomLoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var stopReason: ZoomUserAuthError?
    /// The browser connection carrying the redirect, held open until the code
    /// exchange is known, so the page it shows is true.
    private var pendingClient: Int32 = -1

    private init(fd: Int32, port: UInt16) {
        self.fd = fd
        self.port = port
    }

    static func start(preferredPort: UInt16 = ZoomOAuth.preferredPort) throws -> ZoomLoopbackListener {
        do { return try bind(port: preferredPort) } catch { return try bind(port: 0) }
    }

    private static func bind(port: UInt16) throws -> ZoomLoopbackListener {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ZoomUserAuthError.noPort(String(cString: strerror(errno))) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw ZoomUserAuthError.noPort(why)
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            close(fd)
            throw ZoomUserAuthError.noPort("could not read the assigned port")
        }
        return ZoomLoopbackListener(fd: fd, port: UInt16(bigEndian: assigned.sin_port))
    }

    /// Waits for Zoom's redirect: the code, or the error that says why not.
    /// Ends with `timedOut` after `timeout` seconds and with `cancelled` when
    /// the calling task is cancelled.
    func waitForCode(expectedState: String, timeout: TimeInterval) async throws -> String {
        let timer = DispatchWorkItem { [weak self] in self?.stop(reason: .timedOut) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try self.acceptRedirect(expectedState: expectedState) })
                }
            }
        } onCancel: {
            stop(reason: .cancelled)
        }
    }

    /// Answers the waiting browser tab and closes that connection.
    func reply(success: Bool, detail: String) {
        lock.lock()
        let client = pendingClient
        pendingClient = -1
        lock.unlock()
        guard client >= 0 else { return }
        Self.respond(client, status: "200 OK",
                     html: YouTubeCallbackPage.html(success: success, detail: detail, words: .zoom))
    }

    func stop(reason: ZoomUserAuthError = .cancelled) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        if stopReason == nil { stopReason = reason }
        lock.unlock()
        // A tab still waiting gets an answer rather than a spinner.
        reply(success: false, detail: "Greenroom stopped waiting.")
        // shutdown() is what wakes a blocked accept() on macOS; close alone may not.
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func acceptRedirect(expectedState: String) throws -> String {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                lock.lock(); let reason = stopReason; lock.unlock()
                throw reason ?? ZoomUserAuthError.cancelled
            }
            // A speculative connection that never sends a byte must not stall us.
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = read(client, &buffer, buffer.count)
            let request = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
            let outcome = ZoomCallback.parse(target: ZoomCallback.requestTarget(fromRequest: request),
                                             expectedState: expectedState)
            switch outcome {
            case .code(let code):
                lock.lock(); pendingClient = client; lock.unlock()
                return code
            case .refused(let error, let description):
                let words = ZoomSignInWords.refusal(error: error, description: description)
                Self.respond(client, status: "200 OK",
                             html: YouTubeCallbackPage.html(success: false, detail: words, words: .zoom))
                throw error == "access_denied" ? ZoomUserAuthError.cancelled : ZoomUserAuthError.refused(words)
            case .stateMismatch:
                let words = "The sign-in did not match the one Greenroom started."
                Self.respond(client, status: "200 OK",
                             html: YouTubeCallbackPage.html(success: false, detail: words, words: .zoom))
                throw ZoomUserAuthError.refused(words + " Try again.")
            case .notCallback:
                Self.respond(client, status: "404 Not Found", html: "")
            }
        }
    }

    private static func respond(_ client: Int32, status: String, html: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        _ = response.withCString { write(client, $0, strlen($0)) }
        close(client)
    }
}
