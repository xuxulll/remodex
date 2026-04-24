// FILE: BridgeRuntimeServiceCommands.swift
// Purpose: Handles authenticated bridge requests, local bridge commands, and runtime helper utilities.
// Layer: Companion app service
// Exports: BridgeRuntimeService command extension
// Depends on: Foundation, BridgeRuntimeModels

#if os(macOS)
import Darwin
import Foundation

extension BridgeRuntimeService {
    func handleInboundText(connectionID: String, text: String) async {
        guard let data = text.data(using: .utf8),
              let request = try? JSONDecoder().decode(BridgeClientRequest.self, from: data) else {
            await sendError(
                to: connectionID,
                sessionID: nil,
                messageID: nil,
                message: "Invalid request payload. Expected bridge request JSON."
            )
            return
        }

        await handleRequest(connectionID: connectionID, request: request)
    }

    func handleRequest(connectionID: String, request: BridgeClientRequest) async {
        let settings = await settingsStore.load()

        guard request.type.lowercased() == "request" else {
            await sendError(
                to: connectionID,
                sessionID: request.sessionId,
                messageID: request.messageId,
                message: "Unsupported request type: \(request.type)"
            )
            return
        }

        let token = request.token.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let expectedToken = settings.authToken.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !token.isEmpty, token == expectedToken else {
            await log("Authentication failure from client")
            await sendError(
                to: connectionID,
                sessionID: request.sessionId,
                messageID: request.messageId,
                message: BridgeRuntimeError.invalidToken.localizedDescription
            )
            await server.closeConnection(id: connectionID)
            return
        }

        await log("Request received message_id=\(request.messageId) client_id=\(request.clientId ?? "")")

        let trimmedText = request.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if request.rpcMethod != nil {
            await handleBridgeRPCRequest(connectionID: connectionID, request: request, settings: settings)
            return
        }

        if isBridgeCommand(trimmedText) {
            await handleBridgeCommand(connectionID: connectionID, request: request, text: trimmedText)
            return
        }

        do {
            let codexIsRunning = await processManager.isRunning()
            if !codexIsRunning {
                if settings.autoStartCodexOnBridgeStart {
                    _ = try await startCodexIfNeeded(settings: settings)
                } else {
                    throw BridgeRuntimeError.codexUnavailable(
                        "Codex process is unavailable. Start Codex with `bridge start codex`."
                    )
                }
            }

            guard let codexURL = URL(string: settings.codexListenURL) else {
                throw BridgeRuntimeError.invalidMessage("Invalid Codex URL: \(settings.codexListenURL)")
            }

            await log("Request forwarded to Codex")
            await sessionManager.handleRequest(
                connectionID: connectionID,
                request: request,
                codexURL: codexURL,
                logger: { [weak self] line in
                    Task {
                        await self?.log(line)
                    }
                },
                onSessionCreated: { [weak self] connectionID, sessionID, messageID in
                    await self?.server.sendEvent(
                        BridgeSessionCreatedEvent(sessionId: sessionID, messageId: messageID),
                        to: connectionID
                    )
                    await self?.log("Session created")
                },
                onDelta: { [weak self] connectionID, sessionID, messageID, text in
                    await self?.server.sendEvent(
                        BridgeDeltaEvent(sessionId: sessionID, messageId: messageID, text: text),
                        to: connectionID
                    )
                },
                onCompleted: { [weak self] connectionID, sessionID, messageID in
                    await self?.server.sendEvent(
                        BridgeCompletedEvent(sessionId: sessionID, messageId: messageID),
                        to: connectionID
                    )
                    await self?.log("Codex response completed")
                },
                onError: { [weak self] connectionID, messageID, message, sessionID in
                    await self?.sendError(to: connectionID, sessionID: sessionID, messageID: messageID, message: message)
                }
            )

            runtimeState.activeSessionCount = await sessionManager.sessionCount()
        } catch {
            await sendError(
                to: connectionID,
                sessionID: request.sessionId,
                messageID: request.messageId,
                message: error.localizedDescription
            )
        }
    }

    func handleDisconnect(connectionID: String) async {
        await sessionManager.handleDisconnect(connectionID: connectionID)
        runtimeState.connectedClientCount = await server.connectedClientCount()
    }

    func handleBridgeCommand(connectionID: String, request: BridgeClientRequest, text: String) async {
        do {
            let responseText = try await executeBridgeCommand(text)
            let sessionID = request.sessionId ?? "bridge-command"
            await server.sendEvent(
                BridgeDeltaEvent(sessionId: sessionID, messageId: request.messageId, text: responseText),
                to: connectionID
            )
            await server.sendEvent(
                BridgeCompletedEvent(sessionId: sessionID, messageId: request.messageId),
                to: connectionID
            )
            await log("Bridge command handled locally")
        } catch {
            await sendError(
                to: connectionID,
                sessionID: request.sessionId,
                messageID: request.messageId,
                message: error.localizedDescription
            )
        }
    }

    func handleBridgeRPCRequest(
        connectionID: String,
        request: BridgeClientRequest,
        settings: BridgeRuntimeSettings
    ) async {
        do {
            let codexIsRunning = await processManager.isRunning()
            if !codexIsRunning {
                if settings.autoStartCodexOnBridgeStart {
                    _ = try await startCodexIfNeeded(settings: settings)
                } else {
                    throw BridgeRuntimeError.codexUnavailable(
                        "Codex process is unavailable. Start Codex with `bridge start codex`."
                    )
                }
            }

            guard let codexURL = URL(string: settings.codexListenURL) else {
                throw BridgeRuntimeError.invalidMessage("Invalid Codex URL: \(settings.codexListenURL)")
            }

            await sessionManager.handleRPCRequest(
                connectionID: connectionID,
                request: request,
                codexURL: codexURL,
                logger: { [weak self] line in
                    Task {
                        await self?.log(line)
                    }
                },
                onSessionCreated: { [weak self] connectionID, sessionID, messageID in
                    await self?.server.sendEvent(
                        BridgeSessionCreatedEvent(sessionId: sessionID, messageId: messageID),
                        to: connectionID
                    )
                },
                onRPCResult: { [weak self] connectionID, sessionID, messageID, rpcRequestID, envelope in
                    await self?.server.sendEvent(
                        BridgeRPCResultEvent(
                            sessionId: sessionID,
                            messageId: messageID,
                            rpcRequestId: rpcRequestID,
                            result: envelope.result,
                            error: envelope.error
                        ),
                        to: connectionID
                    )
                },
                onError: { [weak self] connectionID, messageID, message, sessionID in
                    await self?.sendError(
                        to: connectionID,
                        sessionID: sessionID,
                        messageID: messageID,
                        message: message
                    )
                }
            )
            runtimeState.activeSessionCount = await sessionManager.sessionCount()
        } catch {
            await sendError(
                to: connectionID,
                sessionID: request.sessionId,
                messageID: request.messageId,
                message: error.localizedDescription
            )
        }
    }

    func executeBridgeCommand(_ text: String) async throws -> String {
        let normalized = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let parts = normalized.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            return bridgeHelpText()
        }

        let action = parts[1].lowercased()
        switch action {
        case "help":
            return bridgeHelpText()
        case "status":
            return await bridgeStatusText()
        case "settings":
            return await bridgeSettingsText()
        case "start" where parts.count >= 3 && parts[2].lowercased() == "codex":
            try await startCodex()
            return "Codex process started."
        case "stop" where parts.count >= 3 && parts[2].lowercased() == "codex":
            await stopCodex()
            return "Codex process stopped."
        case "restart" where parts.count >= 3 && parts[2].lowercased() == "codex":
            try await restartCodex()
            return "Codex process restarted."
        case "sessions":
            return await bridgeSessionsText()
        case "close" where parts.count >= 4 && parts[2].lowercased() == "session":
            await closeSession(parts[3])
            return "Session \(parts[3]) closed."
        default:
            return bridgeHelpText()
        }
    }

    func bridgeHelpText() -> String {
        [
            "Bridge commands:",
            "bridge status",
            "bridge settings",
            "bridge help",
            "bridge start codex",
            "bridge stop codex",
            "bridge restart codex",
            "bridge sessions",
            "bridge close session <session_id>",
        ].joined(separator: "\n")
    }

    func bridgeStatusText() async -> String {
        let snapshot = await snapshot()
        let status = snapshot.bridgeStatus
        return [
            "Bridge: \(snapshot.launchdLoaded ? "running" : "stopped")",
            "Bridge URL: \(status?.bridgeURL ?? "n/a")",
            "Codex: \((await processManager.isRunning()) ? "running" : "stopped")",
            "Codex URL: \(status?.codexURL ?? "n/a")",
            "Connected clients: \(status?.connectedClientCount ?? 0)",
            "Active sessions: \(status?.activeSessionCount ?? 0)",
        ].joined(separator: "\n")
    }

    func bridgeSettingsText() async -> String {
        let settings = await settingsStore.load()
        let launchArgs = settings.codexLaunchArguments.isEmpty
            ? "(auto)"
            : settings.codexLaunchArguments.joined(separator: " ")
        return [
            "Bridge host: \(settings.bridgeListenHost)",
            "Bridge port: \(settings.bridgePort)",
            "Codex host: \(settings.codexListenHost)",
            "Codex port: \(settings.codexPort)",
            "Codex executable: \(settings.codexExecutablePath)",
            "Codex launch args: \(launchArgs)",
            "Auth token: \(maskToken(settings.authToken))",
            "Auto-start bridge: \(settings.autoStartBridgeOnLaunch)",
            "Auto-start codex: \(settings.autoStartCodexOnBridgeStart)",
            "Debug logging: \(settings.debugLoggingEnabled)",
        ].joined(separator: "\n")
    }

    func bridgeSessionsText() async -> String {
        let sessions = await sessionManager.listSessions()
        guard !sessions.isEmpty else {
            return "No active sessions."
        }

        let formatter = ISO8601DateFormatter()
        return sessions.map { summary in
            let created = formatter.string(from: summary.createdAt)
            let lastActivity = formatter.string(from: summary.lastActivityAt)
            return "session_id=\(summary.sessionId) client_id=\(summary.clientId ?? "-") status=\(summary.connectionStatus) created=\(created) last_activity=\(lastActivity)"
        }.joined(separator: "\n")
    }

    func sendError(to connectionID: String, sessionID: String?, messageID: String?, message: String) async {
        await logs.recordError(message)
        await server.sendEvent(
            BridgeErrorEvent(sessionId: sessionID, messageId: messageID, message: message),
            to: connectionID
        )
    }

    func isBridgeCommand(_ text: String) -> Bool {
        text.lowercased().hasPrefix("bridge")
    }

    func maskToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard trimmed.count > 8 else {
            return "********"
        }
        return "\(trimmed.prefix(4))****\(trimmed.suffix(4))"
    }

    func effectiveBridgeReachableURL(settings: BridgeRuntimeSettings) -> String {
        let host = settings.bridgeListenHost.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if host == "0.0.0.0" || host == "::" {
            let lan = preferredLANIPv4Address() ?? "127.0.0.1"
            return "ws://\(lan):\(settings.bridgePort)"
        }

        return "ws://\(host):\(settings.bridgePort)"
    }

    func preferredLANIPv4Address() -> String? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let firstAddress = addressList else {
            return nil
        }
        defer { freeifaddrs(addressList) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback else {
                continue
            }

            guard let rawAddress = interface.pointee.ifa_addr,
                  rawAddress.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let interfaceName = String(cString: interface.pointee.ifa_name)
            guard interfaceName.hasPrefix("en") else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                rawAddress,
                socklen_t(rawAddress.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else {
                continue
            }

            let candidate = String(cString: hostBuffer)
            if !candidate.isEmpty {
                return candidate
            }
        }

        return nil
    }

    func shortPairingCode(from sessionID: String) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let bytes = Array(sessionID.utf8)
        let code = String((0..<8).map { index in
            let byte = bytes[index % bytes.count]
            return alphabet[Int(byte) % alphabet.count]
        })
        let first = code.prefix(4)
        let second = code.suffix(4)
        return "\(first)-\(second)"
    }

    func log(_ message: String) async {
        let settings = await settingsStore.load()
        if settings.debugLoggingEnabled {
            print("[Bridge] \(message)")
        }
    }

    static func isoTimestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

#endif
