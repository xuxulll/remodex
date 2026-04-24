// FILE: BridgeRuntimeWebSocket.swift
// Purpose: WebSocket listener and client-connection primitives for the bridge server.
// Layer: Companion app service
// Exports: BridgeServer
// Depends on: Foundation, Network, BridgeRuntimeModels

#if os(macOS)
import Foundation
import Network
private final class BridgeWebSocketConnection: @unchecked Sendable {
    let id: String
    let remoteAddress: String
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection) {
        self.id = UUID().uuidString
        self.connection = connection
        self.queue = DispatchQueue(label: "bridge.client.\(UUID().uuidString)")
        self.remoteAddress = BridgeWebSocketConnection.renderRemoteAddress(connection.endpoint)
    }

    func start(
        onText: @escaping @Sendable (String, String) -> Void,
        onClose: @escaping @Sendable (String) -> Void
    ) {
        connection.stateUpdateHandler = { [id] state in
            switch state {
            case .failed, .cancelled:
                onClose(id)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receive(onText: onText, onClose: onClose)
    }

    func send(text: String) async {
        let payload = Data(text.utf8)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "bridge-text", metadata: [metadata])

        await withCheckedContinuation { continuation in
            connection.send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume(returning: ())
            })
        }
    }

    func close() {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "bridge-close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            self.connection.cancel()
        })
    }

    private func receive(
        onText: @escaping @Sendable (String, String) -> Void,
        onClose: @escaping @Sendable (String) -> Void
    ) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                onClose(self.id)
                return
            }

            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                onClose(self.id)
                return
            }

            if let data,
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                onText(self.id, text)
            }

            self.receive(onText: onText, onClose: onClose)
        }
    }

    private static func renderRemoteAddress(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return "unknown"
        }
    }
}

actor BridgeServer {
    private var listener: NWListener?
    private var connections: [String: BridgeWebSocketConnection] = [:]
    private var requestHandler: (@Sendable (String, String) async -> Void)?
    private var disconnectHandler: (@Sendable (String) async -> Void)?
    private var logger: (@Sendable (String) -> Void)?

    func start(
        settings: BridgeRuntimeSettings,
        onRequest: @escaping @Sendable (String, String) async -> Void,
        onDisconnect: @escaping @Sendable (String) async -> Void,
        log: @escaping @Sendable (String) -> Void
    ) throws {
        guard listener == nil else {
            throw BridgeRuntimeError.bridgeAlreadyRunning
        }

        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)
        parameters.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: UInt16(settings.bridgePort)) else {
            throw BridgeRuntimeError.invalidMessage("Invalid bridge port: \(settings.bridgePort)")
        }
        let normalizedHost = settings.bridgeListenHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let listener: NWListener
        if normalizedHost.isEmpty || normalizedHost == "0.0.0.0" || normalizedHost == "::" {
            listener = try NWListener(using: parameters, on: port)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(normalizedHost),
                port: port
            )
            listener = try NWListener(using: parameters)
        }
        let host = settings.bridgeListenHost
        self.requestHandler = onRequest
        self.disconnectHandler = onDisconnect
        self.logger = log

        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                log("Bridge server started on \(host):\(settings.bridgePort)")
            case .failed(let error):
                log("Bridge server failed: \(error.localizedDescription)")
                listener?.cancel()
            case .cancelled:
                log("Bridge server stopped")
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            Task {
                await self.accept(connection: connection)
            }
        }

        listener.start(queue: DispatchQueue(label: "bridge.websocket.listener"))
        self.listener = listener
    }

    func stop() {
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
    }

    func connectedClientCount() -> Int {
        connections.count
    }

    func sendEvent<T: Encodable>(_ event: T, to connectionID: String) async {
        guard let connection = connections[connectionID] else {
            return
        }
        guard let data = try? JSONEncoder().encode(event),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }
        await connection.send(text: payload)
    }

    func sendRawText(_ text: String, to connectionID: String) async {
        guard let connection = connections[connectionID] else {
            return
        }
        await connection.send(text: text)
    }

    func closeConnection(id: String) {
        guard let connection = connections.removeValue(forKey: id) else {
            return
        }
        connection.close()
    }

    private func accept(connection: NWConnection) {
        let client = BridgeWebSocketConnection(connection: connection)
        connections[client.id] = client
        logger?("Client connected: \(client.remoteAddress)")

        client.start(onText: { [weak self] connectionID, text in
            guard let self else { return }
            Task {
                await self.handleInboundText(connectionID: connectionID, text: text)
            }
        }, onClose: { [weak self] connectionID in
            guard let self else { return }
            Task {
                await self.handleDisconnect(connectionID: connectionID)
            }
        })
    }

    private func handleInboundText(connectionID: String, text: String) async {
        await requestHandler?(connectionID, text)
    }

    private func handleDisconnect(connectionID: String) async {
        guard connections.removeValue(forKey: connectionID) != nil else {
            return
        }
        logger?("Client disconnected")
        await disconnectHandler?(connectionID)
    }
}

#endif
