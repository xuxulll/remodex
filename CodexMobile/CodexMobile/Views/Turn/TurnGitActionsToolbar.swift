// FILE: TurnGitActionsToolbar.swift
// Purpose: Encapsulates Git actions toolbar UI for bridge-triggered git operations.
// Layer: View Component
// Exports: TurnGitActionsToolbarButton
// Depends on: SwiftUI, GitActionModels

import SwiftUI

extension TurnGitActionKind {
    var menuAssetName: String? {
        switch self {
        case .syncNow:
            return nil
        case .commit:
            return "git-commit"
        case .push:
            return nil
        case .commitAndPush:
            return "cloud-upload"
        case .createPR:
            return "GitHub_Invertocat_Black"
        case .discardRuntimeChangesAndSync:
            return nil
        }
    }

    var menuSymbolName: String {
        switch self {
        case .syncNow:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .commit:
            return "circle.fill"
        case .push:
            return "arrow.up.circle"
        case .commitAndPush:
            return "circle.fill"
        case .createPR:
            return "circle.fill"
        case .discardRuntimeChangesAndSync:
            return "trash.circle"
        }
    }
}

struct TurnGitActionsToolbarButton: View {
    let isEnabled: Bool
    let disabledActions: Set<TurnGitActionKind>
    let isRunningAction: Bool
    let showsDiscardRuntimeChangesAndSync: Bool
    let gitSyncState: String?
    let onSelect: (TurnGitActionKind) -> Void

    private let minToolbarButtonSize: CGFloat = 28

    private var syncStatusColor: Color? {
        switch gitSyncState {
        case "behind_only", "diverged", "dirty_and_behind":
            return Color(.systemGray2)
        default:
            return nil
        }
    }

    private var syncStatusAccessibilityValue: String? {
        switch gitSyncState {
        case "up_to_date":
            return "Repository up to date"
        case "ahead_only":
            return "Local branch ahead of remote"
        case "behind_only":
            return "Remote branch ahead of local branch"
        case "diverged":
            return "Local and remote branches diverged"
        case "dirty":
            return "Local repository has uncommitted changes"
        case "dirty_and_behind":
            return "Local changes exist and remote branch moved ahead"
        case "no_upstream":
            return "Branch not published yet"
        case "detached_head":
            return "Current branch unavailable"
        default:
            return nil
        }
    }

    var body: some View {
        Menu {
            Section("Update") {
                actionButton(for: .syncNow)
            }

            Section("Write") {
                ForEach([TurnGitActionKind.commit, .push, .commitAndPush, .createPR], id: \.self) { action in
                    actionButton(for: action)
                }
            }

            if !recoveryActions.isEmpty {
                Section("Recovery") {
                    ForEach(recoveryActions, id: \.self) { action in
                        actionButton(for: action)
                    }
                }
            }
        } label: {
            if isRunningAction {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                toolbarIcon(for: .commit, size: 24)
                    .overlay(alignment: .topTrailing) {
                        if let syncStatusColor {
                            Circle()
                                .fill(syncStatusColor)
                                .frame(width: 8, height: 8)
                                .overlay {
                                    Circle()
                                        .stroke(Color(.systemBackground), lineWidth: 1.5)
                                }
                                .offset(x: 2, y: -2)
                        }
                    }
            }
        }
        .controlSize(.small)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.vertical, 4)
        .frame(minWidth: minToolbarButtonSize, minHeight: minToolbarButtonSize)
        .contentShape(Circle())
        .adaptiveToolbarItem(in: Circle())
        .accessibilityLabel("Git actions")
        .accessibilityValue(syncStatusAccessibilityValue ?? "Repository status unavailable")
    }

    private var recoveryActions: [TurnGitActionKind] {
        showsDiscardRuntimeChangesAndSync ? [.discardRuntimeChangesAndSync] : []
    }

    private func actionButton(for action: TurnGitActionKind) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback()
            onSelect(action)
        } label: {
            Label {
                Text(action.title)
            } icon: {
                icon(for: action, size: 20)
            }
        }
        .disabled(!isEnabled || disabledActions.contains(action))
    }

    @ViewBuilder
    private func toolbarIcon(for action: TurnGitActionKind, size: CGFloat) -> some View {
        icon(for: action, size: size)
    }

    @ViewBuilder
    private func icon(for action: TurnGitActionKind, size: CGFloat) -> some View {
        if let assetName = action.menuAssetName {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: action.menuSymbolName)
                .font(.system(size: size, weight: .regular))
                .frame(width: size, height: size)
        }
    }
}
