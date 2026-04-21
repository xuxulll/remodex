// FILE: RemodexMenuBarApp.swift
// Purpose: Entry point for the macOS companion that turns the existing bridge CLI into a menu bar control center.
// Layer: Companion app
// Exports: RemodexMenuBarApp
// Depends on: SwiftUI, BridgeMenuBarStore, BridgeMenuBarViews

import SwiftUI

struct RemodexMenuBarApp: App {
    @StateObject private var store = BridgeMenuBarStore()

    var body: some Scene {
        WindowGroup("Remodex") {
            BridgeDesktopClientView(store: store)
                .frame(minWidth: 520, minHeight: 560)
        }

        MenuBarExtra {
            BridgeMenuBarContentView(store: store)
        } label: {
            BridgeMenuBarLabel(
                snapshot: store.snapshot,
                updateState: store.updateState,
                isBusy: store.isRefreshing || store.isPerformingAction
            )
        }
        .menuBarExtraStyle(.window)
    }
}

private struct BridgeDesktopClientView: View {
    @ObservedObject var store: BridgeMenuBarStore

    var body: some View {
        NavigationStack {
            BridgeMenuBarContentView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Remodex")
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            Task {
                                await store.refresh(showSpinner: true)
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing || store.isPerformingAction)
                    }
                }
        }
    }
}
