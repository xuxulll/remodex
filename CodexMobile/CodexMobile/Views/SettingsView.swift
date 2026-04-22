// FILE: SettingsView.swift
// Purpose: Settings for Local Mode (Codex runs on user's Mac, relay WebSocket).
// Layer: View
// Exports: SettingsView

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import UserNotifications

struct SettingsView: View {
    @Environment(CodexService.self) private var codex

    @AppStorage("codex.appFontStyle") private var appFontStyleRawValue = AppFont.defaultStoredStyleRawValue
    @State private var isShowingMacNameSheet = false
    @State private var remoteRelayAddressDraft = ""
    @State private var remotePairingCodeDraft = ""
    @State private var isConnectingRemoteBridge = false
    @State private var remotePairingErrorMessage: String?

    private let runtimeAutoValue = "__AUTO__"
    private let runtimeNormalValue = "__NORMAL__"
    private let settingsAccentColor = Color(.plan)

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SettingsArchivedChatsCard()
                SettingsAppearanceCard(appFontStyle: appFontStyleBinding)
                SettingsNotificationsCard()
                SettingsGPTAccountCard()
                SettingsBridgeVersionCard()
                runtimeDefaultsSection
                SettingsAboutCard()
                SettingsUsageCard()
                connectionSection
                SettingsBridgeAccessCard()
            }
            .padding()
        }
        .font(AppFont.body())
        .navigationTitle("Settings")
        .sheet(isPresented: $isShowingMacNameSheet) {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                SettingsMacNameSheet(
                    nickname: sidebarMacNicknameBinding(for: trustedPairPresentation),
                    currentName: trustedPairPresentation.name,
                    systemName: trustedPairPresentation.systemName ?? trustedPairPresentation.name
                )
            }
        }
    }

    private var appFontStyleBinding: Binding<AppFont.Style> {
        Binding(
            get: { AppFont.Style(rawValue: appFontStyleRawValue) ?? AppFont.defaultStyle },
            set: { appFontStyleRawValue = $0.rawValue }
        )
    }

    private var keepMacAwakeWhileBridgeRunsBinding: Binding<Bool> {
        Binding(
            get: { codex.keepMacAwakeWhileBridgeRuns },
            set: { nextValue in
                codex.setKeepMacAwakeWhileBridgeRunsPreference(nextValue)
                Task { @MainActor in
                    await codex.syncBridgeKeepMacAwakePreferenceIfNeeded(showFailureInUI: true)
                }
            }
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

    // MARK: - Connection

    @ViewBuilder private var connectionSection: some View {
        SettingsCard(title: "Connection") {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                SettingsTrustedMacCard(
                    presentation: trustedPairPresentation,
                    connectionStatusLabel: connectionStatusLabel,
                    onEditName: {
                        isShowingMacNameSheet = true
                    }
                )
            } else {
                Text("No paired Mac")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
            }

            if connectionPhaseShowsProgress {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(connectionProgressLabel)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            if case .retrying(_, let message) = codex.connectionRecoveryState,
               !message.isEmpty {
                Text(message)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if let error = codex.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
            }

            Divider()

            Toggle("Keep Mac reachable", isOn: keepMacAwakeWhileBridgeRunsBinding)
                .tint(settingsAccentColor)

            Text(codex.keepMacAwakeWhileBridgeRuns
                 ? "Uses macOS caffeinate while the bridge is running so your Mac stays reachable even if the display turns off. Best while charging."
                 : "Your Mac can go back to sleeping normally when the bridge is idle.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            if !codex.isConnected {
                Text("Saved on this device. It will sync to your Mac the next time the bridge reconnects.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if codex.isConnected {
                SettingsButton("Disconnect", role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    disconnectRelay()
                }
            } else if codex.hasTrustedMacReconnectCandidate {
                SettingsButton("Forget Pair", role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    codex.forgetTrustedMac()
                }
            }

            #if os(macOS)
            Divider()
            HStack {
                Text("Connection target")
                Spacer()
                Picker("Connection target", selection: macConnectionTargetSelection) {
                    Text("Local This Mac").tag(CodexMacConnectionTarget.localThisMac)
                    Text("Remote Mac Bridge").tag(CodexMacConnectionTarget.remoteMacBridge)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(settingsAccentColor)
            }

            if codex.macConnectionTarget == .remoteMacBridge {
                Divider()
                remoteBridgePairingSection
            }
            #endif

            if !trustedDeviceRows.isEmpty {
                Divider()
                Text("Trusted Devices")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(trustedDeviceRows, id: \.macDeviceId) { trustedMac in
                    trustedDeviceRow(trustedMac)
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

    // MARK: - Actions

    private func disconnectRelay() {
        Task { @MainActor in
            await codex.disconnect()
            codex.clearSavedRelaySession()
        }
    }

    private var trustedDeviceRows: [CodexTrustedMacRecord] {
        codex.trustedMacRegistry.records.values.sorted { lhs, rhs in
            (lhs.lastUsedAt ?? lhs.lastPairedAt) > (rhs.lastUsedAt ?? rhs.lastPairedAt)
        }
    }

    private var macConnectionTargetSelection: Binding<CodexMacConnectionTarget> {
        Binding(
            get: { codex.macConnectionTarget },
            set: { newTarget in
                codex.setMacConnectionTarget(newTarget)
                remotePairingErrorMessage = nil
                if newTarget == .remoteMacBridge,
                   remoteRelayAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    remoteRelayAddressDraft = codex.normalizedRelayURL ?? ""
                }
            }
        )
    }

    @ViewBuilder
    private func trustedDeviceRow(_ trustedMac: CodexTrustedMacRecord) -> some View {
        let trimmedDisplayName = trustedMac.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = trimmedDisplayName.isEmpty ? "Mac" : trimmedDisplayName
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                Text(codexSecureFingerprint(for: trustedMac.macIdentityPublicKey))
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) {
                codex.forgetTrustedMac(deviceId: trustedMac.macDeviceId)
            }
            .buttonStyle(.borderless)
            .font(AppFont.caption(weight: .semibold))
        }
        .padding(.vertical, 4)
    }

    #if os(macOS)
    @ViewBuilder
    private var remoteBridgePairingSection: some View {
        Text("Remote Bridge Pairing")
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)

        TextField("Relay address (ws://host:port)", text: $remoteRelayAddressDraft)
            .textFieldStyle(.roundedBorder)
            .font(AppFont.mono(.caption))
            .disabled(isConnectingRemoteBridge)

        TextField("Enter pairing code", text: $remotePairingCodeDraft)
            .textFieldStyle(.roundedBorder)
            .font(AppFont.mono(.caption))
            .disabled(isConnectingRemoteBridge)

        HStack(spacing: 8) {
            SettingsButton("Paste Code") {
                pasteRemotePairingCodeFromClipboard()
            }
            .opacity(isConnectingRemoteBridge ? 0.5 : 1)
            .disabled(isConnectingRemoteBridge)

            SettingsButton("Paste Relay") {
                pasteRemoteRelayAddressFromClipboard()
            }
            .opacity(isConnectingRemoteBridge ? 0.5 : 1)
            .disabled(isConnectingRemoteBridge)

            SettingsButton("Connect", isLoading: isConnectingRemoteBridge) {
                connectToRemoteBridgeWithPairingCode()
            }
        }

        if let error = remotePairingErrorMessage,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(error)
                .font(AppFont.caption())
                .foregroundStyle(.orange)
        } else {
            Text("Enter both relay address:port and pair code from the target Mac bridge.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
        }
    }

    private func pasteRemotePairingCodeFromClipboard() {
        let clipboard = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clipboard.isEmpty else {
            return
        }
        remotePairingCodeDraft = clipboard
    }

    private func pasteRemoteRelayAddressFromClipboard() {
        let clipboard = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clipboard.isEmpty else {
            return
        }
        remoteRelayAddressDraft = clipboard
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
                    role: "desktop"
                )
                await codex.refreshBridgeSettingsSnapshot()
                remotePairingCodeDraft = ""
                remotePairingErrorMessage = nil
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
    #endif

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

private struct SettingsBridgeAccessCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase

    @State private var isRefreshing = false
    @State private var isUpdatingLocalBridge = false

    private static let qrContext = CIContext()
    private static let qrSize: CGFloat = 172

    var body: some View {
        SettingsCard(title: "Bridge Access") {
            HStack(spacing: 8) {
                Text("Secure channel")
                Spacer()
                SettingsStatusPill(label: secureChannelLabel)
            }

            if let snapshot = codex.bridgeSettingsSnapshot {
                if let bridgeState = nonEmpty(snapshot.bridgeState)
                    ?? nonEmpty(snapshot.bridgeConnectionStatus) {
                    bridgeInfoRow("Bridge runtime", value: bridgeState, monospaced: false)
                }

                if let pairingPayload = snapshot.pairingPayload {
                    qrPayloadSection(pairingPayload)
                }

                Divider()
                bridgeInfoRow(
                    "Relay",
                    value: nonEmpty(snapshot.relayURL) ?? "Unavailable",
                    monospaced: true
                )
                bridgeInfoRow(
                    "Session",
                    value: nonEmpty(snapshot.relaySessionId) ?? "Unavailable",
                    monospaced: true
                )
                if let pairingCode = nonEmpty(snapshot.pairingCode) {
                    bridgeInfoRow("Pairing code", value: pairingCode, monospaced: true)
                }

                if !snapshot.pairedClientDeviceIds.isEmpty {
                    Divider()
                    Text("Paired Clients")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(snapshot.pairedClientDeviceIds, id: \.self) { clientDeviceId in
                        HStack(spacing: 10) {
                            Text(clientDeviceId)
                                .font(AppFont.mono(.caption))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            SettingsStatusPill(label: "Paired")
                        }
                        .padding(.vertical, 2)
                    }
                }

                Divider()
                Text("Connected Clients (\(snapshot.connectedClientCount))")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.secondary)

                if snapshot.currentClients.isEmpty {
                    Text("No active clients on this bridge session.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.currentClients, id: \.clientDeviceId) { client in
                        connectedClientRow(client)
                    }
                }
            } else if codex.isLoadingBridgeSettingsSnapshot {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading bridge access details...")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Connect to a Mac bridge to view pairing QR and remote session info.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if let error = nonEmpty(codex.bridgeSettingsErrorMessage) {
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.orange)
            }

            #if os(macOS)
            if codex.macConnectionTarget == .localThisMac {
                Divider()
                localBridgeControlSection
            }
            #endif

            SettingsButton("Refresh", isLoading: isRefreshing) {
                refreshSnapshot()
            }
        }
        .task {
            await refreshSnapshotIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await refreshSnapshotIfNeeded()
            }
        }
    }

    private var secureChannelLabel: String {
        codex.bridgeSettingsSnapshot?.secureChannelReady == true ? "Ready" : "Waiting"
    }

    @ViewBuilder
    private func qrPayloadSection(_ payload: CodexPairingQRPayload) -> some View {
        let qrText = bridgePairingPayloadJSONString(payload)

        VStack(alignment: .leading, spacing: 8) {
            Text("Pair on iPhone or iPad")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                if let qrImage = bridgeQRCodeImage(from: qrText) {
                    qrImage
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Self.qrSize, height: Self.qrSize)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                        .frame(width: Self.qrSize, height: Self.qrSize)
                        .overlay(
                            Image(systemName: "qrcode")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.secondary)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan from another device to join this same Mac bridge session.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                    Text("Operations run over this Mac bridge after pairing.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)

                    if let expiresText = pairingExpiryText(from: payload.expiresAt) {
                        Text(expiresText)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bridgeInfoRow(_ title: String, value: String, monospaced: Bool) -> some View {
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

    private func refreshSnapshot() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await codex.refreshBridgeSettingsSnapshot()
            await MainActor.run {
                isRefreshing = false
            }
        }
    }

    private func refreshSnapshotIfNeeded() async {
        #if os(macOS)
        let canReadSnapshot = codex.isConnected || codex.macConnectionTarget == .localThisMac
        #else
        let canReadSnapshot = codex.isConnected
        #endif
        guard canReadSnapshot else { return }
        guard !isRefreshing else { return }

        await MainActor.run {
            isRefreshing = true
        }
        await codex.refreshBridgeSettingsSnapshot()
        await MainActor.run {
            isRefreshing = false
        }
    }

    private func bridgePairingPayloadJSONString(_ payload: CodexPairingQRPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    private func bridgeQRCodeImage(from payloadText: String) -> Image? {
        guard !payloadText.isEmpty else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payloadText.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let transform = CGAffineTransform(scaleX: 8, y: 8)
        let scaledImage = outputImage.transformed(by: transform)

        guard let cgImage = Self.qrContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        #if os(iOS)
        return Image(uiImage: UIImage(cgImage: cgImage))
        #elseif os(macOS)
        return Image(nsImage: NSImage(cgImage: cgImage, size: .zero))
        #else
        return nil
        #endif
    }

    private func pairingExpiryText(from unixSeconds: Int64) -> String? {
        guard unixSeconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        return "QR expires \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    #if os(macOS)
    @ViewBuilder
    private var localBridgeControlSection: some View {
        Text("Local Mac Bridge")
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)

        HStack(spacing: 8) {
            SettingsButton("Start", isLoading: isUpdatingLocalBridge) {
                updateLocalBridge(action: .start)
            }
            SettingsButton("Stop", isLoading: isUpdatingLocalBridge) {
                updateLocalBridge(action: .stop)
            }
            SettingsButton("Reset Pairing", role: .destructive, isLoading: isUpdatingLocalBridge) {
                updateLocalBridge(action: .resetPairing)
            }
        }
    }

    private enum LocalBridgeAction {
        case start
        case stop
        case resetPairing
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
                case .resetPairing:
                    try await codex.resetLocalMacBridgePairing()
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

private struct SettingsBridgeVersionCard: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsCard(title: "Bridge Version") {
            HStack(spacing: 10) {
                Text("Status")
                Spacer()
                SettingsStatusPill(label: versionStatusLabel)
            }

            settingsVersionRow(
                title: "Installed on Mac",
                value: installedVersionLabel,
                valueStyle: installedValueStyle
            )

            settingsVersionRow(
                title: "Latest available",
                value: latestVersionLabel,
                valueStyle: .primary
            )

            if let guidance = guidanceText {
                Text(guidance)
                    .font(AppFont.caption())
                    .foregroundStyle(guidanceColor)
            }
        }
        .task {
            await codex.refreshBridgeVersionState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await codex.refreshBridgeVersionState()
            }
        }
    }

    private var installedVersionLabel: String {
        normalizedVersion(codex.bridgeInstalledVersion) ?? "Unknown"
    }

    private var latestVersionLabel: String {
        normalizedVersion(codex.latestBridgePackageVersion) ?? "Unknown"
    }

    private var guidanceText: String? {
        guard let installedVersion else {
            return "Connect to a Mac bridge to read the installed package version."
        }

        guard let latestVersion else {
            return "Installed version detected. The latest published package is unavailable right now."
        }

        if installedVersion == latestVersion {
            return "The installed bridge matches the latest published package."
        }

        if installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending {
            return "A newer Remodex package is available on npm."
        }

        return "This Mac is running a different build than the current npm latest."
    }

    private var versionStatusLabel: String {
        guard let installedVersion else {
            return "Unknown"
        }

        guard let latestVersion else {
            return "Installed"
        }

        if installedVersion == latestVersion {
            return "Up to date"
        }

        if installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending {
            return "Update available"
        }

        return "Different build"
    }

    private var guidanceColor: Color {
        guard let installedVersion,
              let latestVersion,
              installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending else {
            return .secondary
        }

        return .orange
    }

    private var installedValueStyle: Color {
        guard let installedVersion,
              let latestVersion,
              installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending else {
            return .primary
        }

        return .orange
    }

    private var installedVersion: String? {
        normalizedVersion(codex.bridgeInstalledVersion)
    }

    private var latestVersion: String? {
        normalizedVersion(codex.latestBridgePackageVersion)
    }

    private func normalizedVersion(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func settingsVersionRow(title: String, value: String, valueStyle: Color) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            Text(value)
                .font(AppFont.mono(.subheadline))
                .foregroundStyle(valueStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
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
            NavigationLink {
                ArchivedChatsView()
            } label: {
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
