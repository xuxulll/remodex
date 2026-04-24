// FILE: CodexService+BridgeProtocol.swift
// Purpose: Bridge v2 request/stream adapter for local macOS bridge connections.
// Layer: Service
// Exports: CodexService bridge protocol helpers
// Depends on: BridgeRuntimeModels, RPCMessage

import Foundation

extension CodexService {
    private static let bridgeControlSessionContextID = "__bridge_control__"

    func sendBridgeProtocolRequest(method: String, params: JSONValue?) async throws -> RPCMessage {
        switch method {
        case "initialize":
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        case "turn/start":
            return try await sendBridgeProtocolTurnStart(params: params)
        default:
            return try await sendBridgeProtocolRPC(method: method, params: params)
        }
    }

    func sendBridgeProtocolRPC(method: String, params: JSONValue?) async throws -> RPCMessage {
        guard !bridgeProtocolToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexServiceError.invalidInput("Bridge auth token is missing.")
        }

        let messageID = UUID().uuidString
        let rpcRequestID = UUID().uuidString
        let threadID = params?.objectValue?["threadId"]?.stringValue
        let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionContextID: String
        if let normalizedThreadID, !normalizedThreadID.isEmpty {
            sessionContextID = normalizedThreadID
        } else {
            sessionContextID = Self.bridgeControlSessionContextID
            try await beginBridgeControlBootstrapIfNeeded(for: messageID)
        }
        if let threadID, !threadID.isEmpty {
            bridgeProtocolThreadIDs.insert(threadID)
        }
        bridgeProtocolPendingRPCThreadIDByMessageID[messageID] = sessionContextID
        bridgeProtocolPendingRPCRequestIDByMessageID[messageID] = rpcRequestID

        let request = BridgeClientRequest(
            type: "request",
            token: bridgeProtocolToken,
            clientId: bridgeProtocolClientID,
            sessionId: bridgeProtocolSessionIDByThreadID[sessionContextID],
            messageId: messageID,
            text: "",
            rpcMethod: method,
            rpcParams: bridgeProtocolValue(from: params),
            rpcRequestId: rpcRequestID
        )

        let payload = try JSONEncoder().encode(request)
        let text = String(decoding: payload, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            bridgeProtocolPendingRPCByRequestID[rpcRequestID] = continuation

            Task {
                do {
                    try await sendRawText(text)
                } catch {
                    bridgeProtocolPendingRPCRequestIDByMessageID.removeValue(forKey: messageID)
                    bridgeProtocolPendingRPCThreadIDByMessageID.removeValue(forKey: messageID)
                    failBridgeControlBootstrapIfNeeded(
                        for: messageID,
                        error: error
                    )
                    if let pending = bridgeProtocolPendingRPCByRequestID.removeValue(forKey: rpcRequestID) {
                        pending.resume(throwing: error)
                    }
                }
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self,
                      let pending = self.bridgeProtocolPendingRPCByRequestID.removeValue(forKey: rpcRequestID) else {
                    return
                }
                self.bridgeProtocolPendingRPCThreadIDByMessageID.removeValue(forKey: messageID)
                self.bridgeProtocolPendingRPCRequestIDByMessageID.removeValue(forKey: messageID)
                self.failBridgeControlBootstrapIfNeeded(
                    for: messageID,
                    error: CodexServiceError.invalidInput("No bridge rpc_result for \(method) after 20s.")
                )
                pending.resume(
                    throwing: CodexServiceError.invalidInput("No bridge rpc_result for \(method) after 20s.")
                )
            }
        }
    }

    func sendBridgeProtocolTurnStart(params: JSONValue?) async throws -> RPCMessage {
        let paramsObject = params?.objectValue
        let threadID = paramsObject?["threadId"]?.stringValue ?? UUID().uuidString
        bridgeProtocolThreadIDs.insert(threadID)

        let turnID = UUID().uuidString
        let messageID = UUID().uuidString
        let sessionID = bridgeProtocolSessionIDByThreadID[threadID]
        let inputText = bridgeProtocolInputText(from: paramsObject)

        let request = BridgeClientRequest(
            type: "request",
            token: bridgeProtocolToken,
            clientId: bridgeProtocolClientID,
            sessionId: sessionID,
            messageId: messageID,
            text: inputText,
            rpcMethod: nil,
            rpcParams: nil,
            rpcRequestId: nil
        )

        let requestData = try JSONEncoder().encode(request)
        let requestText = String(decoding: requestData, as: UTF8.self)

        bridgeProtocolPendingThreadIDByMessageID[messageID] = threadID
        bridgeProtocolPendingTurnIDByMessageID[messageID] = turnID

        handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )

        try await sendRawText(requestText)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bridgeProtocolPendingCompletionByMessageID[messageID] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self,
                      let pending = self.bridgeProtocolPendingCompletionByMessageID.removeValue(forKey: messageID) else {
                    return
                }
                self.bridgeProtocolPendingThreadIDByMessageID.removeValue(forKey: messageID)
                self.bridgeProtocolPendingTurnIDByMessageID.removeValue(forKey: messageID)
                pending.resume(throwing: CodexServiceError.invalidInput("No bridge completion after 120s."))
            }
        }

        return RPCMessage(
            id: .string(UUID().uuidString),
            result: .object([
                "turn": .object([
                    "id": .string(turnID),
                ]),
            ]),
            includeJSONRPC: false
        )
    }

    func handleBridgeProtocolIncomingEvent(_ rawText: String) -> Bool {
        guard let data = rawText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }

        switch type {
        case "session_created":
            guard let sessionID = object["session_id"] as? String,
                  let messageID = object["message_id"] as? String else {
                return true
            }

            if let threadID = bridgeProtocolPendingThreadIDByMessageID[messageID] {
                bridgeProtocolSessionIDByThreadID[threadID] = sessionID
            }
            if let threadID = bridgeProtocolPendingRPCThreadIDByMessageID[messageID] {
                bridgeProtocolSessionIDByThreadID[threadID] = sessionID
                if threadID == Self.bridgeControlSessionContextID {
                    completeBridgeControlBootstrapIfNeeded(for: messageID)
                }
            }
            return true

        case "delta":
            guard let messageID = object["message_id"] as? String,
                  let deltaText = object["text"] as? String,
                  let threadID = bridgeProtocolPendingThreadIDByMessageID[messageID],
                  let turnID = bridgeProtocolPendingTurnIDByMessageID[messageID] else {
                return true
            }

            handleNotification(
                method: "codex/event/agent_message_content_delta",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "delta": .string(deltaText),
                    "text": .string(deltaText),
                ])
            )
            return true

        case "completed":
            guard let messageID = object["message_id"] as? String,
                  let threadID = bridgeProtocolPendingThreadIDByMessageID.removeValue(forKey: messageID) else {
                return true
            }

            let turnID = bridgeProtocolPendingTurnIDByMessageID.removeValue(forKey: messageID)
            handleNotification(
                method: "turn/completed",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": turnID.map(JSONValue.string) ?? .null,
                ])
            )
            bridgeProtocolPendingCompletionByMessageID.removeValue(forKey: messageID)?.resume(returning: ())
            return true

        case "rpc_result":
            guard let rpcRequestID = object["rpc_request_id"] as? String,
                  let continuation = bridgeProtocolPendingRPCByRequestID.removeValue(forKey: rpcRequestID) else {
                return true
            }

            if let messageID = object["message_id"] as? String {
                if let threadID = bridgeProtocolPendingRPCThreadIDByMessageID[messageID],
                   let sessionID = object["session_id"] as? String,
                   !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bridgeProtocolSessionIDByThreadID[threadID] = sessionID
                    if threadID == Self.bridgeControlSessionContextID {
                        completeBridgeControlBootstrapIfNeeded(for: messageID)
                    }
                }
                bridgeProtocolPendingRPCThreadIDByMessageID.removeValue(forKey: messageID)
                bridgeProtocolPendingRPCRequestIDByMessageID.removeValue(forKey: messageID)
            }

            if let errorObject = object["error"] as? [String: Any] {
                let message = (errorObject["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "Bridge rpc request failed."
                continuation.resume(throwing: CodexServiceError.invalidInput(message))
                return true
            }

            let resultValue = object["result"].flatMap { bridgeProtocolJSONValue(from: $0) } ?? .object([:])
            continuation.resume(
                returning: RPCMessage(
                    id: .string(rpcRequestID),
                    result: resultValue,
                    includeJSONRPC: false
                )
            )
            return true

        case "error":
            let messageID = object["message_id"] as? String
            let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Bridge request failed."

            if let messageID,
               let rpcRequestID = bridgeProtocolPendingRPCRequestIDByMessageID.removeValue(forKey: messageID),
               let rpcPending = bridgeProtocolPendingRPCByRequestID.removeValue(forKey: rpcRequestID) {
                bridgeProtocolPendingRPCThreadIDByMessageID.removeValue(forKey: messageID)
                failBridgeControlBootstrapIfNeeded(
                    for: messageID,
                    error: CodexServiceError.invalidInput(message)
                )
                rpcPending.resume(throwing: CodexServiceError.invalidInput(message))
                return true
            }

            if let messageID,
               let completion = bridgeProtocolPendingCompletionByMessageID.removeValue(forKey: messageID) {
                bridgeProtocolPendingThreadIDByMessageID.removeValue(forKey: messageID)
                bridgeProtocolPendingTurnIDByMessageID.removeValue(forKey: messageID)
                completion.resume(throwing: CodexServiceError.invalidInput(message))
                return true
            }

            lastErrorMessage = message
            return true

        default:
            return false
        }
    }

    func bridgeProtocolInputText(from paramsObject: RPCObject?) -> String {
        guard let inputItems = paramsObject?["input"]?.arrayValue else {
            return ""
        }

        var chunks: [String] = []
        for item in inputItems {
            guard let object = item.objectValue else {
                continue
            }

            if let text = object["text"]?.stringValue,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(text)
                continue
            }

            if let content = object["content"]?.arrayValue {
                for part in content {
                    guard let contentObject = part.objectValue else {
                        continue
                    }
                    if let text = contentObject["text"]?.stringValue,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        chunks.append(text)
                    }
                }
            }
        }

        return chunks.joined(separator: "\n")
    }

    func bridgeProtocolValue(from value: JSONValue?) -> BridgeRPCValue? {
        guard let value else {
            return nil
        }

        switch value {
        case .string(let v): return .string(v)
        case .integer(let v): return .int(v)
        case .double(let v): return .double(v)
        case .bool(let v): return .bool(v)
        case .array(let arr): return .array(arr.compactMap(bridgeProtocolValue(from:)))
        case .object(let obj):
            var mapped: [String: BridgeRPCValue] = [:]
            for (k, v) in obj {
                mapped[k] = bridgeProtocolValue(from: v)
            }
            return .object(mapped)
        case .null: return .null
        }
    }

    func bridgeProtocolJSONValue(from raw: Any) -> JSONValue? {
        switch raw {
        case let value as String:
            return .string(value)
        case let value as Int:
            return .integer(value)
        case let value as Double:
            return .double(value)
        case let value as Bool:
            return .bool(value)
        case let value as [Any]:
            return .array(value.compactMap(bridgeProtocolJSONValue(from:)))
        case let value as [String: Any]:
            var mapped: [String: JSONValue] = [:]
            for (key, nested) in value {
                if let converted = bridgeProtocolJSONValue(from: nested) {
                    mapped[key] = converted
                }
            }
            return .object(mapped)
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }

    private func beginBridgeControlBootstrapIfNeeded(for messageID: String) async throws {
        guard bridgeProtocolSessionIDByThreadID[Self.bridgeControlSessionContextID] == nil else {
            return
        }

        if let inFlightMessageID = bridgeProtocolControlBootstrapMessageID,
           inFlightMessageID != messageID {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                bridgeProtocolControlBootstrapWaiters.append(continuation)
            }
            return
        }

        bridgeProtocolControlBootstrapMessageID = messageID
    }

    private func completeBridgeControlBootstrapIfNeeded(for messageID: String) {
        guard bridgeProtocolControlBootstrapMessageID == messageID else {
            return
        }

        bridgeProtocolControlBootstrapMessageID = nil
        let waiters = bridgeProtocolControlBootstrapWaiters
        bridgeProtocolControlBootstrapWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: ())
        }
    }

    private func failBridgeControlBootstrapIfNeeded(for messageID: String, error: Error) {
        guard bridgeProtocolControlBootstrapMessageID == messageID else {
            return
        }

        bridgeProtocolControlBootstrapMessageID = nil
        let waiters = bridgeProtocolControlBootstrapWaiters
        bridgeProtocolControlBootstrapWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}
