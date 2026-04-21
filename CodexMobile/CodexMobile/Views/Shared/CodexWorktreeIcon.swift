// FILE: CodexWorktreeIcon.swift
// Purpose: Shared fork + worktree icons so branching affordances stay visually aligned across the app.
// Layer: View Component
// Exports: CodexForkIcon, CodexWorktreeIcon, CodexWorktreeMenuLabelRow
// Depends on: SwiftUI, AppFont

import SwiftUI

struct CodexForkIcon: View {
    var pointSize: CGFloat = 13

    var body: some View {
        Image("git-branch")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: pointSize, height: pointSize)
    }
}

struct CodexWorktreeIcon: View {
    var pointSize: CGFloat = 13
    var weight: Font.Weight = .regular

    var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: pointSize, weight: weight))
            .rotationEffect(.degrees(90))
            .frame(width: pointSize, height: pointSize)
    }
}

struct CodexWorktreeMenuLabelRow: View {
    let title: String
    var pointSize: CGFloat = 13
    var weight: Font.Weight = .regular

    var body: some View {
        HStack(spacing: 10) {
            CodexWorktreeIcon(pointSize: pointSize, weight: weight)
            Text(title)
        }
    }
}
