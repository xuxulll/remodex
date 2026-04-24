// FILE: BridgeCodexSessionChannel.swift
// Purpose: Per-session websocket bridge to Codex app-server with request/stream handling.
// Layer: Companion app service
// Exports: CodexSessionChannel
// Depends on: Foundation, BridgeRuntimeModels

#if os(macOS)
import Foundation
actor CodexSessionChannel {
    private let codexURL: URL
    private let logger: @Sendable (String) -> Void
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<BridgeRPCEnvelope, Error>] = [:]
    private var requestIndex: Int = 0
    private var initialized = false
    private var threadID: String?
    private var activeMessageID: String?
    private var activeCompletion: CheckedContinuation<Void, Error>?
    private var onDelta: (@Sendable (String) async -> Void)?

    init(codexURL: URL, logger: @escaping @Sendable (String) -> Void) {
        self.codexURL = codexURL
        self.logger = logger
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    func sendUserText(
        _ text: String,
        messageID: String,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws {
        guard activeMessageID == nil else {
            throw BridgeRuntimeError.invalidSession("Session is already processing a request.")
        }

        try await ensureConnected()

        if threadID == nil {
            threadID = try await createThread()
        }

        guard let threadID else {
            throw BridgeRuntimeError.invalidSession("Unable to establish Codex thread for session.")
        }

        activeMessageID = messageID
        self.onDelta = onDelta

        let params: [String: BridgeRPCValue] = [
            "threadId": .string(threadID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ]),
            ]),
        ]

        _ = try await sendRequest(method: "turn/start", params: .object(params))

        try await withCheckedThrowingContinuation { continuation in
            self.activeCompletion = continuation
        }

        activeMessageID = nil
        activeCompletion = nil
        self.onDelta = nil
    }

    func sendRPCRequest(method: String, params: BridgeRPCValue?) async throws -> BridgeRPCEnvelope {
        try await ensureConnected()
        return try await sendRequest(method: method, params: params)
    }

    func close() {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        initialized = false
        threadID = nil
        activeMessageID = nil
        activeCompletion?.resume(throwing: BridgeRuntimeError.invalidSession("Session closed."))
        activeCompletion = nil
        for continuation in pendingRequests.values {
            continuation.resume(throwing: BridgeRuntimeError.invalidSession("Session closed."))
        }
        pendingRequests.removeAll()
    }

    private func ensureConnected() async throws {
        if webSocketTask != nil {
            return
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: codexURL)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()

        urlSession = session
        webSocketTask = task

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        try await initializeIfNeeded()
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else {
            return
        }

        let clientInfo: [String: BridgeRPCValue] = [
            "name": .string("remodex_bridge"),
            "title": .string("Remodex Bridge"),
            "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"),
        ]
        let params: [String: BridgeRPCValue] = [
            "clientInfo": .object(clientInfo),
            "capabilities": .object([
                "experimentalApi": .bool(true),
            ]),
        ]

        do {
            _ = try await sendRequest(method: "initialize", params: .object(params))
        } catch {
            _ = try await sendRequest(method: "initialize", params: .object(["clientInfo": .object(clientInfo)]))
        }

        try await sendNotification(method: "initialized", params: nil)
        initialized = true
    }

    private func createThread() async throws -> String {
        let response = try await sendRequest(method: "thread/start", params: .object([:]))
        guard let result = response.result?.objectValue,
              let thread = result["thread"]?.objectValue,
              let id = thread["id"]?.stringValue,
              !id.isEmpty else {
            throw BridgeRuntimeError.invalidSession("Codex response did not include a thread id.")
        }
        return id
    }

    private func sendRequest(method: String, params: BridgeRPCValue?) async throws -> BridgeRPCEnvelope {
        let requestID = nextRequestID()
        let envelope = BridgeRPCEnvelope(id: .string(requestID), method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            Task {
                do {
                    try await self.sendEnvelope(envelope)
                } catch {
                    if let continuation = self.pendingRequests.removeValue(forKey: requestID) {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func sendNotification(method: String, params: BridgeRPCValue?) async throws {
        let envelope = BridgeRPCEnvelope(id: nil, method: method, params: params)
        try await sendEnvelope(envelope)
    }

    private func sendEnvelope(_ envelope: BridgeRPCEnvelope) async throws {
        guard let task = webSocketTask else {
            throw BridgeRuntimeError.codexUnavailable("Codex websocket is not connected.")
        }
        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BridgeRuntimeError.invalidMessage("Failed to encode Codex request.")
        }
        try await task.send(.string(text))
    }

    private func receiveLoop() async {
        while let task = webSocketTask {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    await handleIncomingText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleIncomingText(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                await failAllPending(error: error)
                return
            }
        }
    }

    private func handleIncomingText(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(BridgeRPCEnvelope.self, from: data) else {
            return
        }

        if let id = envelope.id?.stringValue,
           let continuation = pendingRequests.removeValue(forKey: id) {
            if let error = envelope.error {
                continuation.resume(throwing: BridgeRuntimeError.invalidMessage(error.message))
            } else {
                continuation.resume(returning: envelope)
            }
            return
        }

        guard let method = envelope.method else {
            return
        }

        let normalized = method.lowercased()

        if normalized.contains("agent_message_content_delta") || normalized.contains("agent_message_delta") {
            if let delta = extractText(from: envelope.params), !delta.isEmpty {
                await onDelta?(delta)
            }
            return
        }

        if normalized == "codex/event/agent_message",
           let text = extractText(from: envelope.params),
           !text.isEmpty {
            await onDelta?(text)
            return
        }

        if normalized == "turn/completed" || normalized == "item/completed" {
            activeCompletion?.resume(returning: ())
            activeCompletion = nil
            return
        }

        if normalized.contains("turn/failed") || normalized.contains("error") {
            let message = extractText(from: envelope.params) ?? "Codex turn failed"
            activeCompletion?.resume(throwing: BridgeRuntimeError.invalidMessage(message))
            activeCompletion = nil
        }
    }

    private func failAllPending(error: Error) {
        for continuation in pendingRequests.values {
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
        activeCompletion?.resume(throwing: error)
        activeCompletion = nil
        activeMessageID = nil
    }

    private func extractText(from value: BridgeRPCValue?) -> String? {
        guard let value else {
            return nil
        }

        if let string = value.stringValue {
            return string
        }

        if let object = value.objectValue {
            let keys = ["delta", "text", "message", "output_text", "outputText", "content"]
            for key in keys {
                if let direct = object[key]?.stringValue,
                   !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return direct
                }
            }

            for nested in object.values {
                if let nestedText = extractText(from: nested),
                   !nestedText.isEmpty {
                    return nestedText
                }
            }
        }

        if let array = value.arrayValue {
            for item in array {
                if let nestedText = extractText(from: item),
                   !nestedText.isEmpty {
                    return nestedText
                }
            }
        }

        return nil
    }

    private func nextRequestID() -> String {
        requestIndex += 1
        return "bridge-\(requestIndex)-\(UUID().uuidString)"
    }
}

#endif
