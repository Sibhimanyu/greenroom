//
//  PrompterTransport.swift
//  Greenroom
//
//  Everything LinkResolver needs from the network, behind one protocol.
//
//  Phase 2 of docs/prompter-search-improvement-plan.md asks for source clients
//  that tests can stand in for, so resolution can be scored without depending
//  on what Wikipedia happens to return today. The resolver used to hold a
//  URLSession directly, which made every ranking decision in it unmeasurable:
//  the only way to exercise "does the right card win for this phrase" was to
//  ask the live internet and hope it answered the same way twice.
//
//  Two methods, because the resolver does two different things with a socket.
//  The APIs return JSON in one piece. A product's homepage is read only as far
//  as its </title>, which was worth doing - downloading whole homepages was the
//  slowest thing Prompter did - and that streaming decision belongs on this
//  side of the line, where a recorded answer can simply hand back the string.
//
import Foundation

protocol PrompterTransport: Sendable {
    /// A whole JSON body.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Text read until `marker` appears or `byteCap` bytes have arrived,
    /// whichever comes first. Returns whatever was read either way.
    func text(for request: URLRequest, stoppingAfter marker: String,
              byteCap: Int) async throws -> (String, HTTPURLResponse)
}

/// The real one. Ephemeral session, short timeouts, a descriptive User-Agent
/// that a site owner reading their logs can identify.
struct URLSessionTransport: PrompterTransport {
    private let session: URLSession

    init(userAgent: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "application/json"]
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    func text(for request: URLRequest, stoppingAfter marker: String,
              byteCap: Int) async throws -> (String, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else { return ("", http) }

        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= byteCap { break }
            // Checked on '>' rather than on every byte: decoding the buffer to
            // a String per byte is what makes this expensive, and the marker
            // can only ever complete on one.
            if byte == UInt8(ascii: ">"), buffer.count > 32,
               let text = Self.decode(buffer),
               text.range(of: marker, options: .caseInsensitive) != nil {
                return (text, http)
            }
        }
        return (Self.decode(buffer) ?? "", http)
    }

    /// Pages that lie about their encoding are common enough to be worth the
    /// second attempt; isoLatin1 never fails, so this only returns nil on empty.
    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// A transport that answers from a table instead of the network.
///
/// Used by the bench so retrieval and ranking can be scored on the same bytes
/// every time. Anything it was not given answers 404, which is deliberate: a
/// fixture that reaches a URL nobody recorded should fail loudly rather than
/// quietly fall through to a search link and look like a pass.
struct RecordedTransport: PrompterTransport {
    struct Reply {
        var status = 200
        var body: String
    }

    /// Keyed by URL string. Matched exactly first, then by prefix, so a
    /// recording does not have to reproduce query-parameter order.
    let replies: [String: Reply]
    /// Every URL asked for, in order. The bench prints unmatched ones.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func note(_ url: String) { lock.lock(); urls.append(url); lock.unlock() }
        var requested: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    }
    let log = Log()

    func reply(for request: URLRequest) -> Reply {
        let asked = request.url?.absoluteString ?? ""
        log.note(asked)
        if let exact = replies[asked] { return exact }
        for (key, reply) in replies where asked.hasPrefix(key) { return reply }
        return Reply(status: 404, body: "")
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = reply(for: request)
        let http = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                   httpVersion: nil, headerFields: nil)!
        return (Data(reply.body.utf8), http)
    }

    func text(for request: URLRequest, stoppingAfter marker: String,
              byteCap: Int) async throws -> (String, HTTPURLResponse) {
        let reply = reply(for: request)
        let http = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                   httpVersion: nil, headerFields: nil)!
        return (reply.status == 200 ? String(reply.body.prefix(byteCap)) : "", http)
    }
}
