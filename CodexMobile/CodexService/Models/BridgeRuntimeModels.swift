// FILE: BridgeRuntimeModels.swift
// Purpose: Config and wire models for the local-first macOS bridge runtime.
// Layer: Companion app model
// Exports: bridge settings + bridge wire payloads
// Depends on: Foundation

import Foundation

struct BridgeRuntimeSettings: Codable, Equatable, Sendable {
    var bridgeListenHost: String
    var bridgePort: Int
    var codexListenHost: String
    var codexPort: Int
    var codexExecutablePath: String
    var codexLaunchArguments: [String]
    var authToken: String
    var autoStartBridgeOnLaunch: Bool
    var autoStartCodexOnBridgeStart: Bool
    var debugLoggingEnabled: Bool

    static let `default` = BridgeRuntimeSettings(
        bridgeListenHost: "0.0.0.0",
        bridgePort: 9010,
        codexListenHost: "127.0.0.1",
        codexPort: 9009,
        codexExecutablePath: "/opt/homebrew/bin/codex",
        codexLaunchArguments: [],
        authToken: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        autoStartBridgeOnLaunch: true,
        autoStartCodexOnBridgeStart: true,
        debugLoggingEnabled: false
    )

    var codexListenURL: String {
        "ws://\(codexListenHost):\(codexPort)"
    }

    var bridgeListenURL: String {
        "ws://\(bridgeListenHost):\(bridgePort)"
    }
}

struct BridgeClientRequest: Codable, Sendable {
    let type: String
    let token: String
    let clientId: String?
    let sessionId: String?
    let messageId: String
    let text: String
    let rpcMethod: String?
    let rpcParams: BridgeRPCValue?
    let rpcRequestId: String?

    init(
        type: String,
        token: String,
        clientId: String?,
        sessionId: String?,
        messageId: String,
        text: String,
        rpcMethod: String? = nil,
        rpcParams: BridgeRPCValue? = nil,
        rpcRequestId: String? = nil
    ) {
        self.type = type
        self.token = token
        self.clientId = clientId
        self.sessionId = sessionId
        self.messageId = messageId
        self.text = text
        self.rpcMethod = rpcMethod
        self.rpcParams = rpcParams
        self.rpcRequestId = rpcRequestId
    }

    enum CodingKeys: String, CodingKey {
        case type
        case token
        case clientId = "client_id"
        case sessionId = "session_id"
        case messageId = "message_id"
        case text
        case rpcMethod = "rpc_method"
        case rpcParams = "rpc_params"
        case rpcRequestId = "rpc_request_id"
    }
}

struct BridgeSessionCreatedEvent: Codable, Sendable {
    let type = "session_created"
    let sessionId: String
    let messageId: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case messageId = "message_id"
    }
}

struct BridgeDeltaEvent: Codable, Sendable {
    let type = "delta"
    let sessionId: String
    let messageId: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case messageId = "message_id"
        case text
    }
}

struct BridgeCompletedEvent: Codable, Sendable {
    let type = "completed"
    let sessionId: String
    let messageId: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case messageId = "message_id"
    }
}

struct BridgeErrorEvent: Codable, Sendable {
    let type = "error"
    let sessionId: String?
    let messageId: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case messageId = "message_id"
        case message
    }
}

struct BridgeRPCResultEvent: Codable, Sendable {
    let type = "rpc_result"
    let sessionId: String
    let messageId: String
    let rpcRequestId: String
    let result: BridgeRPCValue?
    let error: BridgeRPCError?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case messageId = "message_id"
        case rpcRequestId = "rpc_request_id"
        case result
        case error
    }
}

struct BridgeSessionSummary: Codable, Equatable, Sendable {
    let sessionId: String
    let clientId: String?
    let connectionStatus: String
    let createdAt: Date
    let lastActivityAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case clientId = "client_id"
        case connectionStatus = "connection_status"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
    }
}

struct BridgeRuntimeState: Sendable {
    var bridgeRunning = false
    var codexRunning = false
    var codexProcessID: Int?
    var connectedClientCount = 0
    var activeSessionCount = 0
    var recentErrors: [String] = []
    var codexCLIAvailability: BridgeCLIAvailability = .checking
}

struct BridgeRPCEnvelope: Codable, Sendable {
    let jsonrpc: String?
    let id: BridgeRPCValue?
    let method: String?
    let params: BridgeRPCValue?
    let result: BridgeRPCValue?
    let error: BridgeRPCError?

    init(id: BridgeRPCValue? = nil, method: String, params: BridgeRPCValue? = nil) {
        self.jsonrpc = nil
        self.id = id
        self.method = method
        self.params = params
        self.result = nil
        self.error = nil
    }

    init(id: BridgeRPCValue?, result: BridgeRPCValue?) {
        self.jsonrpc = nil
        self.id = id
        self.method = nil
        self.params = nil
        self.result = result
        self.error = nil
    }

    init(id: BridgeRPCValue?, error: BridgeRPCError) {
        self.jsonrpc = nil
        self.id = id
        self.method = nil
        self.params = nil
        self.result = nil
        self.error = error
    }
}

struct BridgeRPCError: Codable, Sendable {
    let code: Int
    let message: String
    let data: BridgeRPCValue?
}

enum BridgeRPCValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([BridgeRPCValue])
    case object([String: BridgeRPCValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let array = try? container.decode([BridgeRPCValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: BridgeRPCValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(
                BridgeRPCValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: BridgeRPCValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [BridgeRPCValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}
