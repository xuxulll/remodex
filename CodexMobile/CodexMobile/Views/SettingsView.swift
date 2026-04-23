// FILE: SettingsView.swift
// Purpose: Settings for Local Mode (Codex runs on user's Mac, relay WebSocket).
// Layer: View
// Exports: SettingsView

import SwiftUI
#if os(iOS)
import UIKit
#endif
import UserNotifications

enum SettingsNavigation: Identifiable {
    case archivedChats
    
    var id: Self { self }
}

struct SettingsView: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("codex.appFontStyle") private var appFontStyleRawValue = AppFont.defaultStoredStyleRawValue
    @State private var isShowingMacNameSheet = false
    @State private var isShowingRemoteBridgeSheet = false
    @State private var remoteRelayAddressDraft = ""
    @State private var remotePairingCodeDraft = ""
    @State private var isConnectingRemoteBridge = false
    @State private var remotePairingErrorMessage: String?
    @State private var isRefreshingBridgeInfo = false
    @State private var isUpdatingLocalBridge = false
    @State private var isUpdatingCaffeinate = false
    @State private var prefersRemoteBridge = false

    @State private var navigationPath: [SettingsNavigation] = []
    
    private let runtimeAutoValue = "__AUTO__"
    private let runtimeNormalValue = "__NORMAL__"
    private let settingsAccentColor = Color(.plan)

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 24) {
                    SettingsArchivedChatsCard()
                    SettingsAppearanceCard(appFontStyle: appFontStyleBinding)
                    SettingsNotificationsCard()
                    SettingsGPTAccountCard()
                    runtimeDefaultsSection
                    SettingsUsageCard()
                    bridgeSection
                    SettingsAboutCard()
                }
                .padding()
            }
            .font(AppFont.body())
            .navigationTitle("Settings")
            .task {
                await refreshBridgeInfoIfNeeded()
                #if os(macOS)
                prefersRemoteBridge = codex.macConnectionTarget == .remoteMacBridge
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await refreshBridgeInfoIfNeeded()
                }
            }
            .sheet(isPresented: $isShowingMacNameSheet) {
                if let trustedPairPresentation = codex.trustedPairPresentation {
                    SettingsMacNameSheet(
                        nickname: sidebarMacNicknameBinding(for: trustedPairPresentation),
                        currentName: trustedPairPresentation.name,
                        systemName: trustedPairPresentation.systemName ?? trustedPairPresentation.name
                    )
                }
            }
            .sheet(isPresented: $isShowingRemoteBridgeSheet) {
                remoteBridgePairingSheet
            }
            .navigationDestination(for: SettingsNavigation.self) { target in
                switch target {
                case .archivedChats:
                    ArchivedChatsView()
                }
            }
        }
    }

    private var appFontStyleBinding: Binding<AppFont.Style> {
        Binding(
            get: { AppFont.Style(rawValue: appFontStyleRawValue) ?? AppFont.defaultStyle },
            set: { appFontStyleRawValue = $0.rawValue }
        )
    }

    // MARK: - Runtime defaults

    @ViewBuilder private var runtimeDefaultsSection: some View {
        SettingsCard(title: "Runtime defaults") {
            HStack {
                Text("Model")
                Spacer()
                Picker("Model", selection: runtimeModelSelection) {
                    Text("Auto").tag(runtimeAutoValue)
                    ForEach(runtimeModelOptions, id: \.id) { model in
                        Text(TurnComposerMetaMapper.modelTitle(for: model))
                            .tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
            }

            HStack {
                Text("Reasoning")
                Spacer()
                Picker("Reasoning", selection: runtimeReasoningSelection) {
                    Text("Auto").tag(runtimeAutoValue)
                    ForEach(runtimeReasoningOptions, id: \.id) { option in
                        Text(option.title).tag(option.effort)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
                .disabled(runtimeReasoningOptions.isEmpty)
            }

            HStack {
                Text("Speed")
                Spacer()
                Picker("Speed", selection: runtimeServiceTierSelection) {
                    Text("Normal").tag(runtimeNormalValue)
                    ForEach(CodexServiceTier.allCases, id: \.rawValue) { tier in
                        Text(tier.displayName).tag(tier.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
            }

            HStack {
                Text("Access")
                Spacer()
                Picker("Access", selection: runtimeAccessSelection) {
                    ForEach(CodexAccessMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
            }
        }
    }

    // MARK: - Bridge

    @ViewBuilder private var bridgeSection: some View {
        SettingsCard(title: "Bridge") {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                SettingsTrustedMacCard(
                    presentation: trustedPairPresentation,
                    connectionStatusLabel: connectionStatusLabel,
                    onEditName: {
                        isShowingMacNameSheet = true
                    }
                )
            }

            #if os(macOS)
            Toggle("Use Remote Bridge", isOn: useRemoteBridgeToggle)
                .tint(settingsAccentColor)
            #endif

            HStack(spacing: 8) {
                Text("Status")
                Spacer()
                SettingsStatusPill(label: connectionStatusLabel.capitalized)
            }

            if connectionPhaseShowsProgress {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(connectionProgressLabel)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            if let relayAddress = connectedRelayAddress {
                bridgeInfoRow(title: "Relay", value: relayAddress, monospaced: true)
            }

            bridgeInfoRow(title: "Mac Bridge Version", value: installedBridgeVersion, monospaced: true)

            if codex.isConnected {
                Divider()
                bridgeConnectedDevicesSection
                Divider()
                bridgeLogsSection
                Divider()
            }

            if let error = nonEmpty(codex.bridgeSettingsErrorMessage) ?? nonEmpty(codex.lastErrorMessage) {
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.orange)
            }

            SettingsButton("Refresh Bridge Info", isLoading: isRefreshingBridgeInfo) {
                refreshBridgeInfo()
            }

            if codex.isConnected {
                SettingsButton(
                    codex.keepMacAwakeWhileBridgeRuns ? "Disable Caffeinate" : "Enable Caffeinate",
                    isLoading: isUpdatingCaffeinate
                ) {
                    updateCaffeinate(enabled: !codex.keepMacAwakeWhileBridgeRuns)
                }

                Text(
                    codex.keepMacAwakeWhileBridgeRuns
                    ? "Bridge keeps your Mac awake via `caffeinate -ims`."
                    : "Bridge will stop using `caffeinate -ims` and allow normal sleep."
                )
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
            }

            #if os(macOS)
            if isConnectedToLocalBridge {
                if let pairingCode = nonEmpty(codex.bridgeSettingsSnapshot?.pairingCode) {
                    bridgeInfoRow(title: "Local Pairing Code", value: pairingCode, monospaced: true)
                }
            }
            localBridgeControlSection
            #endif

            if isConnectedToRemoteBridge {
                SettingsButton("Disconnect", role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    disconnectRelay()
                }
            } else if !codex.isConnected {
                SettingsButton("Set Up Remote Bridge") {
                    prepareRemoteBridgeSheet()
                }
            }
        }
    }

    private var connectionPhaseShowsProgress: Bool {
        switch codex.connectionPhase {
        case .connecting, .loadingChats, .syncing:
            return true
        case .offline, .connected:
            return false
        }
    }

    private var connectionStatusLabel: String {
        switch codex.connectionPhase {
        case .offline:
            return "offline"
        case .connecting:
            return "connecting"
        case .loadingChats:
            return "loading chats"
        case .syncing:
            return "syncing"
        case .connected:
            return "connected"
        }
    }

    private var connectionProgressLabel: String {
        switch codex.connectionPhase {
        case .connecting:
            return "Connecting to relay..."
        case .loadingChats:
            return "Loading chats..."
        case .syncing:
            return "Syncing workspace..."
        case .offline, .connected:
            return ""
        }
    }

    private var installedBridgeVersion: String {
        let macAppVersion = nonEmpty(codex.bridgeSettingsSnapshot?.macAppVersion)
        let macAppBuild = nonEmpty(codex.bridgeSettingsSnapshot?.macAppBuild)

        if let macAppVersion, let macAppBuild {
            return "\(macAppVersion) (\(macAppBuild))"
        }
        if let macAppVersion {
            return macAppVersion
        }
        if let macAppBuild {
            return "Build \(macAppBuild)"
        }
        if let bridgeVersion = normalizedVersion(codex.bridgeInstalledVersion) {
            return bridgeVersion
        }
        return "Unknown"
    }

    private var connectedRelayAddress: String? {
        if let snapshotRelay = nonEmpty(codex.bridgeSettingsSnapshot?.relayURL) {
            return snapshotRelay
        }
        #if os(macOS)
        if isConnectedToLocalBridge {
            return codex.normalizedLocalBridgeServerURL
        }
        #endif
        return codex.normalizedRelayURL
    }

    private var latestBridgeLogs: [String] {
        Array(codex.runtimeDebugLogEntries.suffix(10))
    }

    private var isConnectedToRemoteBridge: Bool {
        codex.isConnected && !isConnectedToLocalBridge
    }

    private var isConnectedToLocalBridge: Bool {
        #if os(macOS)
        return codex.isConnected
            && codex.macConnectionTarget == .localThisMac
            && codex.normalizedLocalBridgeServerURL != nil
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var bridgeConnectedDevicesSection: some View {
        let clients = codex.bridgeSettingsSnapshot?.currentClients ?? []
        Text("Connected Devices (\(clients.count))")
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)

        if clients.isEmpty {
            Text("No active clients on this bridge.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
        } else {
            ForEach(clients, id: \.clientDeviceId) { client in
                connectedClientRow(client)
            }
        }
    }

    @ViewBuilder
    private var bridgeLogsSection: some View {
        Text("Bridge Logs (Latest 10)")
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)

        if latestBridgeLogs.isEmpty {
            Text("No bridge logs yet.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(latestBridgeLogs.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(AppFont.mono(.caption))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    @ViewBuilder
    private func bridgeInfoRow(title: String, value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
            if monospaced {
                Text(value)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(AppFont.caption())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func connectedClientRow(_ client: CodexBridgeConnectedClient) -> some View {
        let normalizedClientName = client.clientName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = normalizedClientName?.isEmpty == false
            ? (normalizedClientName ?? client.clientDeviceId)
            : client.clientDeviceId
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(client.clientDeviceId)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Key epoch \(client.keyEpoch)")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsStatusPill(label: client.isResumed ? "Resumed" : "Handshaking")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var remoteBridgePairingSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Remote Bridge")
                    .font(AppFont.subheadline(weight: .semibold))

                TextField("Relay address (ws://host:port)", text: $remoteRelayAddressDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.mono(.caption))
                    .disabled(isConnectingRemoteBridge)

                TextField("Enter pairing code", text: $remotePairingCodeDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.mono(.caption))
                    .disabled(isConnectingRemoteBridge)

                SettingsButton("Test & Connect", isLoading: isConnectingRemoteBridge) {
                    connectToRemoteBridgeWithPairingCode()
                }

                if let error = remotePairingErrorMessage,
                   !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(error)
                        .font(AppFont.caption())
                        .foregroundStyle(.orange)
                } else {
                    Text("Enter relay address and pairing code, then Remodex will test, save, and connect.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .navigationTitle("Remote Bridge")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        #if os(macOS)
                        prefersRemoteBridge = codex.macConnectionTarget == .remoteMacBridge
                        #endif
                        isShowingRemoteBridgeSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func disconnectRelay() {
        Task { @MainActor in
            await codex.disconnect()
            codex.clearSavedRelaySession()
        }
    }

    private func refreshBridgeInfo() {
        guard !isRefreshingBridgeInfo else { return }
        isRefreshingBridgeInfo = true
        Task {
            await codex.refreshBridgeSettingsSnapshot()
            await codex.refreshBridgeVersionState()
            await MainActor.run {
                isRefreshingBridgeInfo = false
            }
        }
    }

    private func refreshBridgeInfoIfNeeded() async {
        #if os(macOS)
        let canRefresh = codex.isConnected || codex.macConnectionTarget == .localThisMac
        #else
        let canRefresh = codex.isConnected
        #endif
        guard canRefresh else { return }
        guard !isRefreshingBridgeInfo else { return }

        await MainActor.run {
            isRefreshingBridgeInfo = true
        }
        await codex.refreshBridgeSettingsSnapshot()
        await codex.refreshBridgeVersionState()
        await MainActor.run {
            isRefreshingBridgeInfo = false
        }
    }

    private func prepareRemoteBridgeSheet() {
        remotePairingErrorMessage = nil
        if remoteRelayAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remoteRelayAddressDraft = codex.normalizedRelayURL ?? ""
        }
        isShowingRemoteBridgeSheet = true
    }

    private func updateCaffeinate(enabled: Bool) {
        guard !isUpdatingCaffeinate else { return }
        isUpdatingCaffeinate = true
        Task {
            await codex.updateBridgeKeepMacAwakePreference(enabled)
            await MainActor.run {
                isUpdatingCaffeinate = false
            }
        }
    }

    #if os(macOS)
    private var useRemoteBridgeToggle: Binding<Bool> {
        Binding(
            get: { prefersRemoteBridge },
            set: { useRemote in
                if useRemote {
                    prefersRemoteBridge = true
                    prepareRemoteBridgeSheet()
                    return
                }
                prefersRemoteBridge = false
                codex.setMacConnectionTarget(.localThisMac)
                Task { @MainActor in
                    await reconnectAfterConnectionTargetSwitchIfNeeded()
                }
            }
        )
    }

    @ViewBuilder
    private var localBridgeControlSection: some View {
        Text("Local Bridge Controls")
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)

        HStack(spacing: 8) {
            SettingsButton("Start", isLoading: isUpdatingLocalBridge) {
                updateLocalBridge(action: .start)
            }
            SettingsButton("Stop", isLoading: isUpdatingLocalBridge) {
                updateLocalBridge(action: .stop)
            }
            SettingsButton("Restart", isLoading: isUpdatingLocalBridge) {
                updateLocalBridge(action: .restart)
            }
        }
    }

    private enum LocalBridgeAction {
        case start
        case stop
        case restart
    }

    private func updateLocalBridge(action: LocalBridgeAction) {
        guard !isUpdatingLocalBridge else { return }
        isUpdatingLocalBridge = true
        Task {
            do {
                switch action {
                case .start:
                    try await codex.startLocalMacBridge()
                case .stop:
                    try await codex.stopLocalMacBridge()
                case .restart:
                    try await codex.stopLocalMacBridge()
                    try await codex.startLocalMacBridge()
                }
                await codex.refreshBridgeSettingsSnapshot()
                await MainActor.run {
                    codex.bridgeSettingsErrorMessage = nil
                    isUpdatingLocalBridge = false
                }
            } catch {
                await MainActor.run {
                    codex.bridgeSettingsErrorMessage = error.localizedDescription
                    isUpdatingLocalBridge = false
                }
            }
        }
    }
    #endif

    private func reconnectAfterConnectionTargetSwitchIfNeeded() async {
        guard codex.isConnected || codex.isConnecting else {
            return
        }

        await codex.disconnect(preserveReconnectIntent: false)
        guard let reconnectURL = reconnectURLForSelectedConnectionTarget() else {
            return
        }

        do {
            try await codex.connect(
                serverURL: reconnectURL,
                token: "",
                role: currentClientRole
            )
        } catch {
            if codex.lastErrorMessage?.isEmpty ?? true {
                codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
            }
        }
    }

    private func reconnectURLForSelectedConnectionTarget() -> String? {
        #if os(macOS)
        if codex.macConnectionTarget == .localThisMac,
           let localBridgeURL = codex.normalizedLocalBridgeServerURL {
            return localBridgeURL
        }
        #endif

        guard let relayURL = codex.normalizedRelayURL else {
            return nil
        }

        if codex.shouldUseDirectRelayTransport {
            return relayURL
        }

        guard let sessionId = codex.normalizedRelaySessionId else {
            return nil
        }

        return "\(relayURL)/\(sessionId)"
    }

    private func connectToRemoteBridgeWithPairingCode() {
        guard !isConnectingRemoteBridge else {
            return
        }

        let code = remotePairingCodeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            remotePairingErrorMessage = "Enter a valid pairing code."
            return
        }
        guard let relayURL = normalizedRemoteRelayURL(from: remoteRelayAddressDraft) else {
            remotePairingErrorMessage = "Enter a valid relay address including port."
            return
        }

        isConnectingRemoteBridge = true
        remotePairingErrorMessage = nil

        Task { @MainActor in
            defer { isConnectingRemoteBridge = false }

            do {
                let pairingPayload: CodexPairingQRPayload
                do {
                    pairingPayload = try await codex.resolvePairingCode(
                        code,
                        relayURLOverride: relayURL
                    )
                } catch {
                    guard isLikelyDirectSessionCode(code) else {
                        throw error
                    }
                    guard isLikelyDirectAppServerEndpoint(relayURL) else {
                        throw CodexSecureTransportError.invalidQR(
                            "This looks like a relay endpoint. Use the target Mac bridge app-server "
                                + "address:port (for LAN usually `ws://<mac-lan-ip>:9010`) or a relay "
                                + "that supports pairing-code resolve."
                        )
                    }
                    let directRelayURL = normalizedDirectAppServerRelayURL(from: relayURL)
                    pairingPayload = CodexPairingQRPayload(
                        v: codexPairingQRVersion,
                        relay: directRelayURL,
                        sessionId: code,
                        macDeviceId: "remote-mac",
                        macIdentityPublicKey: "",
                        expiresAt: Int64(Date().timeIntervalSince1970 * 1000) + (5 * 60 * 1000),
                        transport: .directAppServer
                    )
                }
                let connectURL: String
                if pairingPayload.transport == .directAppServer {
                    connectURL = pairingPayload.relay
                } else {
                    connectURL = "\(pairingPayload.relay)/\(pairingPayload.sessionId)"
                }

                codex.setMacConnectionTarget(.remoteMacBridge)
                await codex.disconnect(preserveReconnectIntent: false)
                codex.rememberRelayPairing(pairingPayload)
                try await codex.connect(
                    serverURL: connectURL,
                    token: "",
                    role: currentClientRole
                )
                await codex.refreshBridgeSettingsSnapshot()
                await codex.refreshBridgeVersionState()
                remotePairingCodeDraft = ""
                remotePairingErrorMessage = nil
                #if os(macOS)
                prefersRemoteBridge = true
                #endif
                isShowingRemoteBridgeSheet = false
            } catch {
                remotePairingErrorMessage = error.localizedDescription
            }
        }
    }

    private func normalizedRemoteRelayURL(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "ws://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              components.port != nil else {
            return nil
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string
    }

    private func isLikelyDirectSessionCode(_ rawCode: String) -> Bool {
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalized = trimmed
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if UUID(uuidString: trimmed) != nil {
            return true
        }
        if trimmed.range(
            of: "^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}$",
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(of: "^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$", options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private var currentClientRole: String {
        #if os(macOS)
        "desktop"
        #else
        "iphone"
        #endif
    }

    private func normalizedDirectAppServerRelayURL(from relayURL: String) -> String {
        guard var components = URLComponents(string: relayURL),
              components.host != nil else {
            return relayURL
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? relayURL
    }

    private func isLikelyDirectAppServerEndpoint(_ relayURL: String) -> Bool {
        guard let components = URLComponents(string: relayURL) else {
            return false
        }

        let normalizedPath = components.path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedPath.isEmpty || normalizedPath == "/" {
            return components.port != 9000
        }

        return !normalizedPath.hasSuffix("/relay")
    }

    private func normalizedVersion(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Runtime bindings

    private var runtimeModelOptions: [CodexModelOption] {
        TurnComposerMetaMapper.orderedModels(from: codex.availableModels)
    }

    private var runtimeReasoningOptions: [TurnComposerReasoningDisplayOption] {
        TurnComposerMetaMapper.reasoningDisplayOptions(
            from: codex.supportedReasoningEffortsForSelectedModel().map(\.reasoningEffort)
        )
    }

    private var runtimeModelSelection: Binding<String> {
        Binding(
            get: { codex.selectedModelOption()?.id ?? runtimeAutoValue },
            set: { selection in
                codex.setSelectedModelId(selection == runtimeAutoValue ? nil : selection)
            }
        )
    }

    private var runtimeReasoningSelection: Binding<String> {
        Binding(
            get: { codex.selectedReasoningEffort ?? runtimeAutoValue },
            set: { selection in
                codex.setSelectedReasoningEffort(selection == runtimeAutoValue ? nil : selection)
            }
        )
    }

    private var runtimeAccessSelection: Binding<CodexAccessMode> {
        Binding(
            get: { codex.selectedAccessMode },
            set: { codex.setSelectedAccessMode($0) }
        )
    }

    private var runtimeServiceTierSelection: Binding<String> {
        Binding(
            get: { codex.selectedServiceTier?.rawValue ?? runtimeNormalValue },
            set: { selection in
                codex.setSelectedServiceTier(
                    selection == runtimeNormalValue ? nil : CodexServiceTier(rawValue: selection)
                )
            }
        )
    }

    // Writes nicknames against the active trusted Mac so switching pairs does not reuse the wrong alias.
    private func sidebarMacNicknameBinding(for presentation: CodexTrustedPairPresentation) -> Binding<String> {
        Binding(
            get: { SidebarMacNicknameStore.nickname(for: presentation.deviceId) },
            set: { SidebarMacNicknameStore.setNickname($0, for: presentation.deviceId) }
        )
    }
}

// MARK: - Reusable card / button components

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

struct SettingsButton: View {
    let title: String
    var role: ButtonRole?
    var isLoading: Bool = false
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                }
            }
            .font(AppFont.subheadline(weight: .medium))
            .foregroundStyle(role == .destructive ? .red : (role == .cancel ? .secondary : .primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                (role == .destructive ? Color.red : Color.primary).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Extracted independent section views

private struct SettingsUsageCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase

    @State private var isRefreshing = false

    var body: some View {
        SettingsCard(title: "Usage") {
            UsageStatusSummaryContent(
                contextWindowUsage: nil,
                showsContextWindowSection: false,
                rateLimitBuckets: codex.rateLimitBuckets,
                isLoadingRateLimits: codex.isLoadingRateLimits,
                rateLimitsErrorMessage: codex.rateLimitsErrorMessage,
                refreshControl: UsageStatusRefreshControl(
                    title: "Refresh",
                    isRefreshing: isRefreshing,
                    action: refreshStatus
                )
            )
        }
        .task {
            await refreshStatusIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await refreshStatusIfNeeded()
            }
        }
    }

    private func refreshStatus() {
        guard !isRefreshing else { return }
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        isRefreshing = true

        Task {
            await refreshStatusData()
            await MainActor.run {
                isRefreshing = false
            }
        }
    }

    private func refreshStatusIfNeeded() async {
        guard !isRefreshing else { return }
        guard codex.shouldAutoRefreshUsageStatus(threadId: nil) else { return }

        await MainActor.run {
            isRefreshing = true
        }
        await refreshStatusData()
        await MainActor.run {
            isRefreshing = false
        }
    }

    // Settings only needs the account-wide usage windows.
    private func refreshStatusData() async {
        await codex.refreshUsageStatus(threadId: nil)
    }
}

private struct SettingsAppearanceCard: View {
    @Binding var appFontStyle: AppFont.Style
    @AppStorage("codex.useLiquidGlass") private var useLiquidGlass = true
    private let settingsAccentColor = Color(.plan)

    var body: some View {
        SettingsCard(title: "Appearance") {
            HStack {
                Text("Font")
                Spacer()
                Picker("Font", selection: $appFontStyle) {
                    ForEach(AppFont.Style.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
            }

            Text(appFontStyle.subtitle)
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            if GlassPreference.isSupported {
                Divider()

                Toggle("Liquid Glass", isOn: $useLiquidGlass)
                    .tint(settingsAccentColor)

                Text(useLiquidGlass
                     ? "Liquid Glass effects are enabled."
                     : "Using solid material fallback.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsNotificationsCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsCard(title: "Notifications") {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .foregroundStyle(.primary)
                Text("Status")
                Spacer()
                Text(statusLabel)
                    .foregroundStyle(.secondary)
            }

            Text("Used for local alerts when a run finishes while the app is in background.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            if codex.notificationAuthorizationStatus == .notDetermined {
                SettingsButton("Allow notifications") {
                    HapticFeedback.shared.triggerImpactFeedback()
                    Task {
                        await codex.requestNotificationPermission()
                    }
                }
            }

            if codex.notificationAuthorizationStatus == .denied {
                SettingsButton(openSystemSettingsLabel) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    openSystemNotificationSettings()
                }
            }
        }
        .task {
            await codex.refreshManagedNotificationRegistrationState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            Task {
                await codex.refreshManagedNotificationRegistrationState()
            }
        }
    }

    private var statusLabel: String {
        switch codex.notificationAuthorizationStatus {
        case .authorized: "Authorized"
        case .denied: "Denied"
        case .provisional: "Provisional"
        #if os(iOS)
        case .ephemeral: "Ephemeral"
        #endif
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }

    private var openSystemSettingsLabel: String {
        #if os(iOS)
        return "Open iOS Settings"
        #else
        return "Open System Settings"
        #endif
    }

    private func openSystemNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            openURL(url)
        }
        #endif
    }
}

private struct SettingsGPTAccountCard: View {
    @State private var isShowingMacLoginInfo = false

    var body: some View {
        SettingsCard(title: "ChatGPT voice mode") {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                isShowingMacLoginInfo = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(AppFont.subheadline(weight: .medium))
                    Text("Info")
                        .font(AppFont.subheadline(weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $isShowingMacLoginInfo) {
            GPTVoiceSetupSheet()
        }
    }
}

private struct SettingsArchivedChatsCard: View {
    @Environment(CodexService.self) private var codex

    private var archivedCount: Int {
        codex.threads.filter { $0.syncState == .archivedLocal }.count
    }

    var body: some View {
        SettingsCard(title: "Archived Chats") {
            NavigationLink(value: SettingsNavigation.archivedChats) {
                HStack {
                    Label("Archived Chats", systemImage: "archivebox")
                        .font(AppFont.subheadline(weight: .medium))
                    Spacer()
                    if archivedCount > 0 {
                        Text("\(archivedCount)")
                            .font(AppFont.caption(weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SettingsAboutCard: View {
    @Environment(\.openURL) private var openURL
    @State private var isShowingAbout = false

    var body: some View {
        SettingsCard(title: "About") {
            Text("Chats are End-to-end encrypted between your iPhone and Mac. The relay only sees ciphertext and connection metadata after the secure handshake completes.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                isShowingAbout = true
            } label: {
                settingsAccessoryRow(
                    title: "How Remodex Works",
                    leading: {
                        Image(systemName: "info.circle")
                            .font(AppFont.subheadline(weight: .medium))
                    }
                )
            }
            .buttonStyle(.plain)

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                if let url = URL(string: "https://x.com/emanueledpt") {
                    openURL(url)
                }
            } label: {
                settingsAccessoryRow(
                    title: "Chat & Support",
                    leading: {
                        Image("x-icon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                    }
                )
            }
            .buttonStyle(.plain)

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                openURL(AppEnvironment.privacyPolicyURL)
            } label: {
                settingsAccessoryRow(
                    title: "Privacy Policy",
                    leading: {
                        Image(systemName: "hand.raised")
                            .font(AppFont.subheadline(weight: .medium))
                    }
                )
            }
            .buttonStyle(.plain)

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                openURL(AppEnvironment.termsOfUseURL)
            } label: {
                settingsAccessoryRow(
                    title: "Terms of Use",
                    leading: {
                        Image(systemName: "doc.text")
                            .font(AppFont.subheadline(weight: .medium))
                    }
                )
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $isShowingAbout) {
            AboutRemodexView()
        }
    }

    // Keeps settings rows visually consistent while allowing SF Symbols or asset icons.
    private func settingsAccessoryRow<Leading: View>(
        title: String,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 8) {
            leading()
            Text(title)
                .font(AppFont.subheadline(weight: .medium))
            Spacer()
            Image(systemName: "chevron.right")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

private struct SettingsTrustedMacCard: View {
    let presentation: CodexTrustedPairPresentation
    let connectionStatusLabel: String
    let onEditName: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.06))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mac")
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(presentation.name)
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }

                Spacer(minLength: 8)

                Button(action: onEditName) {
                    Image(systemName: "pencil")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit Mac name")
            }

            HStack(spacing: 8) {
                SettingsStatusPill(label: connectionStatusLabel.capitalized)

                if let title = compactTitle {
                    SettingsStatusPill(label: title)
                }
            }

            if let systemName = presentation.systemName,
               !systemName.isEmpty {
                labeledRow("System", value: systemName)
            }

            if let detail = presentation.detail,
               !detail.isEmpty {
                labeledRow("Status", value: detail)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemFill).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var compactTitle: String? {
        let trimmed = presentation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder
    private func labeledRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Text(value)
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsStatusPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }
}

private struct SettingsMacNameSheet: View {
    @Binding var nickname: String
    let currentName: String
    let systemName: String

    @Environment(\.dismiss) private var dismiss
    @State private var draftNickname = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mac name")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(currentName)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }

                TextField(systemName, text: $draftNickname)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    #endif
                    .font(AppFont.subheadline())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemFill))
                    )

                Text("This nickname stays on this device and appears anywhere this Mac is shown.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    SettingsButton("Use Default", role: .cancel) {
                        nickname = ""
                        dismiss()
                    }
                    .opacity(canResetToDefault ? 1 : 0.5)
                    .disabled(!canResetToDefault)

                    SettingsButton("Save") {
                        nickname = draftNickname
                        dismiss()
                    }
                    .opacity(canSave ? 1 : 0.5)
                    .disabled(!canSave)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
            .navigationTitle("Edit Mac Name")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                draftNickname = nickname
            }
        }
    }

    private var canSave: Bool {
        draftNickname != nickname
    }

    private var canResetToDefault: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(CodexService())
    }
}
