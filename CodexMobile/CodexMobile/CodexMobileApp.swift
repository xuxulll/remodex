// FILE: CodexMobileApp.swift
// Purpose: App entry point and root dependency wiring.
// Layer: App
// Exports: CodexMobileApp

import SwiftUI

@MainActor
@main
struct RemodexApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CodexMobileAppDelegate.self) private var appDelegate
    #endif
    @State private var interactionService: RemodexInteractionService
    #if os(macOS)
    @StateObject private var bridgeMenuStore = BridgeMenuBarStore()
    #endif

    init() {
        _interactionService = State(
            initialValue: RemodexInteractionService(codexService: CodexService())
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(interactionService.codexService)
                .onOpenURL { url in
                    Task { @MainActor in
                        guard CodexService.legacyGPTLoginCallbackEnabled else {
                            return
                        }
                        await interactionService.codexService.handleGPTLoginCallbackURL(url)
                    }
                }
                #if os(iOS)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    interactionService.handleMemoryWarning()
                }
                #endif
                .onChange(of: scenePhase) { _, newPhase in
                    interactionService.handleScenePhaseChange(newPhase)
                }
        }

        #if os(macOS)
        MenuBarExtra {
            BridgeMenuBarContentView(store: bridgeMenuStore)
        } label: {
            BridgeMenuBarLabel(
                snapshot: bridgeMenuStore.snapshot,
                updateState: bridgeMenuStore.updateState,
                isBusy: bridgeMenuStore.isRefreshing || bridgeMenuStore.isPerformingAction
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            NavigationStack {
                SettingsView()
                    .environment(interactionService.codexService)
            }
        }
        #endif
    }
}
