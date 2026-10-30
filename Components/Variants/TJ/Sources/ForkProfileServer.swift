//
// TJ fork: one-shot loopback server for the Home Screen web-clip profile (iOS Workshop, Element card).
// Based on Element X iOS. SPDX-License-Identifier: AGPL-3.0-only
//
// Spec: WatchLab/Element/03_ARTIFACTS_SPEC.md rev 3.4, §13.4 + §13.6 (privacy).
// - Binds 127.0.0.1 only (required local endpoint), random port.
// - Serves exactly one path, `/<32 random hex>.mobileconfig`, with `application/x-apple-aspen-config`; anything else is 404.
// - Stops after the first complete download or after 8 minutes, whichever comes first. Nothing is uploaded anywhere.
// - A UIKit background task keeps the app running while Safari (now in front) fetches the file.
//

import Foundation
import Network
import OSLog
import UIKit

nonisolated final class ForkProfileServer: @unchecked Sendable {
    enum ServeError: Error {
        case listenerFailed
    }

    static let lifetime: TimeInterval = 8 * 60

    private let queue = DispatchQueue(label: "tj.homescreen.profile-server")
    private let logger = Logger(subsystem: "tj.artifacts", category: "homescreen")
    // All mutable state below is only touched on `queue`.
    private var listener: NWListener?
    private var payload = Data()
    private var path = ""
    private var served = false
    private var deadline: DispatchWorkItem?
    private var onStop: (@Sendable () -> Void)?
    private var startContinuation: CheckedContinuation<URL, Error>?

    /// Starts a fresh listener (stopping any previous one) and returns the one URL that serves `profile`.
    func start(profile: Data, onStop: @escaping @Sendable () -> Void) async throws -> URL {
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.stopLocked(reason: "replaced")
                self.payload = profile
                self.path = "/\(token).mobileconfig"
                self.served = false
                self.onStop = onStop
                do {
                    let parameters = NWParameters.tcp
                    // Bound to 127.0.0.1, so only this device can connect. Not `acceptLocalOnly`: on iOS 27 that listener never
                    // delivered Safari's loopback connection (G-H3 run 2: TCP connected, no accept; "SO_NECP_LISTENUUID failed").
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.startContinuation = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener?.port?.rawValue, let pending = self.startContinuation else { return }
                            self.startContinuation = nil
                            self.logger.notice("TJHOME profile server listening on 127.0.0.1:\(port, privacy: .public)")
                            pending.resume(returning: URL(string: "http://127.0.0.1:\(port)\(self.path)")!)
                        case .failed, .cancelled:
                            if let pending = self.startContinuation {
                                self.startContinuation = nil
                                pending.resume(throwing: ServeError.listenerFailed)
                            }
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: self.queue)
                    let deadline = DispatchWorkItem { [weak self] in self?.stopLocked(reason: "8 minutes") }
                    self.deadline = deadline
                    self.queue.asyncAfter(deadline: .now() + Self.lifetime, execute: deadline)
                } catch {
                    continuation.resume(throwing: ServeError.listenerFailed)
                }
            }
        }
    }

    func stop() {
        queue.async { self.stopLocked(reason: "closed") }
    }

    // MARK: - Private (on `queue`)

    private func stopLocked(reason: String) {
        deadline?.cancel()
        deadline = nil
        if let pending = startContinuation {
            startContinuation = nil
            pending.resume(throwing: ServeError.listenerFailed)
        }
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        payload = Data()
        logger.notice("TJHOME profile server stopped (\(reason, privacy: .public))")
        let callback = onStop
        onStop = nil
        callback?()
    }

    private func accept(_ connection: NWConnection) {
        logger.notice("TJHOME connection accepted")
        connection.stateUpdateHandler = { [weak self] state in
            self?.logger.notice("TJHOME connection state \(String(describing: state), privacy: .public)")
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            self.logger.notice("TJHOME received \(data?.count ?? 0, privacy: .public) bytes complete=\(isComplete, privacy: .public) error=\(String(describing: error), privacy: .public)")
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(on: connection, request: buffer)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, request: Data) {
        let line = String(decoding: request.prefix(while: { $0 != 0x0D && $0 != 0x0A }), as: UTF8.self)
        let parts = line.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let target = parts.count > 1 ? String(parts[1]) : ""
        let matches = listener != nil && !served && (method == "GET" || method == "HEAD") && target == path
        logger.notice("TJHOME request \(method, privacy: .public) matches=\(matches, privacy: .public)")
        guard matches else {
            send(on: connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8), finished: nil)
            return
        }
        let isHead = method == "HEAD"
        let body = payload
        send(on: connection, status: "200 OK", contentType: ForkWebClipProfile.contentType, body: isHead ? Data() : body, length: body.count) { [weak self] ok in
            guard let self, ok, !isHead else { return }
            self.served = true
            self.logger.notice("TJHOME profile served once (\(body.count, privacy: .public) bytes)")
            self.stopLocked(reason: "downloaded")
        }
    }

    private func send(on connection: NWConnection, status: String, contentType: String, body: Data, length: Int? = nil, finished: (@Sendable (Bool) -> Void)?) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(length ?? body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { error in
            finished?(error == nil)
            connection.cancel()
        })
    }
}

/// App-side wrapper: one server per process. The profile is fetched by an in-app Safari view (SFSafariViewController), so the
/// app stays in front while the loopback listener answers: with the app in the background (Safari in front) the listener
/// received no connection on iOS 27 (G-H3 run 1: "the network connection was lost"). A background task still covers a
/// short trip to Settings.
@MainActor
final class ForkProfileInstaller {
    static let shared = ForkProfileInstaller()

    private let server = ForkProfileServer()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Starts serving `profile` and returns the one URL to open in the in-app Safari view (nil if the listener failed).
    func serve(profile: Data) async -> URL? {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "tj.homescreen.profile") { [weak self] in
            self?.server.stop()
            self?.endBackgroundTask()
        }
        do {
            return try await server.start(profile: profile) { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        } catch {
            endBackgroundTask()
            return nil
        }
    }

    func stop() {
        server.stop()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
