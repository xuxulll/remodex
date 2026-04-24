import Foundation
import Testing
@testable import CodexService

#if os(macOS)

@Suite("Bridge Runtime Integration")
struct BridgeRuntimeIntegrationTests {
    private let facade = BridgeRuntimeFacade.shared
    private let bridgePort = 19010
    private let codexPort = 19009
    private let token = "bridge-test-token"

    @Test("Bridge command handling")
    func bridgeCommandHandling() async throws {
        try await configureAndStartBridge(autoStartCodex: false)
        defer {
            Task {
                await facade.stopBridge()
            }
        }

        let client = TestBridgeClient(url: URL(string: "ws://127.0.0.1:\(bridgePort)")!)
        defer {
            Task {
                await client.close()
            }
        }

        try await client.send(
            BridgeClientRequest(
                type: "request",
                token: token,
                clientId: "test-client",
                sessionId: nil,
                messageId: "msg-bridge-help",
                text: "bridge help"
            )
        )

        let events = try await client.collectEvents(count: 2)
        #expect(events.contains(where: { $0.contains("\"type\":\"delta\"") }))
        #expect(events.contains(where: { $0.contains("bridge help") }))
        #expect(events.contains(where: { $0.contains("\"type\":\"completed\"") }))
    }

    @Test("Authentication rejection")
    func authenticationRejection() async throws {
        try await configureAndStartBridge(autoStartCodex: false)
        defer {
            Task {
                await facade.stopBridge()
            }
        }

        let client = TestBridgeClient(url: URL(string: "ws://127.0.0.1:\(bridgePort)")!)
        defer {
            Task {
                await client.close()
            }
        }

        try await client.send(
            BridgeClientRequest(
                type: "request",
                token: "invalid-token",
                clientId: "test-client",
                sessionId: nil,
                messageId: "msg-auth",
                text: "bridge status"
            )
        )

        let first = try await client.receive()
        #expect(first.contains("\"type\":\"error\""))
        #expect(first.contains("Authentication failed"))
    }

    @Test("Codex process restart")
    func codexProcessRestart() async throws {
        let settings = await configureBaseSettings(autoStartCodex: false)
        let availability = await facade.detectCLIAvailability()
        guard availability.isAvailable else {
            throw Skip("Codex CLI is unavailable in this environment.")
        }

        await facade.saveSettings(settings)
        try await facade.startCodex()
        try await facade.restartCodex()
        await facade.stopCodex()
    }

    @Test("Session isolation")
    func sessionIsolation() async throws {
        let availability = await facade.detectCLIAvailability()
        guard availability.isAvailable else {
            throw Skip("Codex CLI is unavailable in this environment.")
        }

        try await configureAndStartBridge(autoStartCodex: true)
        defer {
            Task {
                await facade.stopCodex()
                await facade.stopBridge()
            }
        }

        let clientA = TestBridgeClient(url: URL(string: "ws://127.0.0.1:\(bridgePort)")!)
        let clientB = TestBridgeClient(url: URL(string: "ws://127.0.0.1:\(bridgePort)")!)
        defer {
            Task {
                await clientA.close()
                await clientB.close()
            }
        }

        try await clientA.send(
            BridgeClientRequest(
                type: "request",
                token: token,
                clientId: "client-A",
                sessionId: nil,
                messageId: "session-create",
                text: "hello"
            )
        )

        let createdEvent = try await clientA.receive()
        #expect(createdEvent.contains("\"type\":\"session_created\""))

        guard let sessionID = TestBridgeClient.extractSessionID(from: createdEvent) else {
            Issue.record("Failed to parse session_id from session_created event")
            return
        }

        try await clientB.send(
            BridgeClientRequest(
                type: "request",
                token: token,
                clientId: "client-B",
                sessionId: sessionID,
                messageId: "isolation-check",
                text: "hello"
            )
        )

        let error = try await clientB.receive()
        #expect(error.contains("\"type\":\"error\""))
        #expect(error.contains("does not belong to this client"))
    }

    @Test("Normal request forwarding")
    func normalRequestForwarding() async throws {
        let availability = await facade.detectCLIAvailability()
        guard availability.isAvailable else {
            throw Skip("Codex CLI is unavailable in this environment.")
        }

        try await configureAndStartBridge(autoStartCodex: true)
        defer {
            Task {
                await facade.stopCodex()
                await facade.stopBridge()
            }
        }

        let client = TestBridgeClient(url: URL(string: "ws://127.0.0.1:\(bridgePort)")!)
        defer {
            Task {
                await client.close()
            }
        }

        try await client.send(
            BridgeClientRequest(
                type: "request",
                token: token,
                clientId: "forward-client",
                sessionId: nil,
                messageId: "forward-msg",
                text: "Say hello briefly"
            )
        )

        var sawSession = false
        var sawCompleted = false

        for _ in 0..<30 {
            let event = try await client.receive(timeout: 2)
            if event.contains("\"type\":\"session_created\"") {
                sawSession = true
            }
            if event.contains("\"type\":\"completed\"") {
                sawCompleted = true
                break
            }
        }

        #expect(sawSession)
        #expect(sawCompleted)
    }

    private func configureAndStartBridge(autoStartCodex: Bool) async throws {
        let settings = await configureBaseSettings(autoStartCodex: autoStartCodex)
        await facade.saveSettings(settings)
        await facade.stopBridge()
        await facade.stopCodex()
        try await facade.startBridge()
    }

    private func configureBaseSettings(autoStartCodex: Bool) async -> BridgeRuntimeSettings {
        var settings = await facade.loadSettings()
        settings.bridgeListenHost = "0.0.0.0"
        settings.bridgePort = bridgePort
        settings.codexListenHost = "127.0.0.1"
        settings.codexPort = codexPort
        settings.authToken = token
        settings.autoStartBridgeOnLaunch = false
        settings.autoStartCodexOnBridgeStart = autoStartCodex
        settings.debugLoggingEnabled = false
        settings.codexLaunchArguments = []
        return settings
    }
}

private final class TestBridgeClient {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.session = session
        self.task = task
    }

    func send(_ request: BridgeClientRequest) async throws {
        let payload = try JSONEncoder().encode(request)
        let text = String(decoding: payload, as: UTF8.self)
        try await task.send(.string(text))
    }

    func receive(timeout: TimeInterval = 3) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let message = try await self.task.receive()
                switch message {
                case .string(let text):
                    return text
                case .data(let data):
                    return String(decoding: data, as: UTF8.self)
                @unknown default:
                    return ""
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TestClientError.timedOut
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    func collectEvents(count: Int) async throws -> [String] {
        var events: [String] = []
        for _ in 0..<count {
            events.append(try await receive())
        }
        return events
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    static func extractSessionID(from event: String) -> String? {
        guard let data = event.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = object["session_id"] as? String,
              !sessionID.isEmpty else {
            return nil
        }
        return sessionID
    }
}

private enum TestClientError: Error {
    case timedOut
}

#endif
