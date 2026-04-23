// FILE: TurnSessionDiffResetMarker.swift
// Purpose: Hidden marker payloads used to reset unpushed git diff summaries after manual push.
// Layer: Model
// Exports: TurnSessionDiffResetMarker
// Depends on: Foundation, CodexMessage

import Foundation

enum TurnSessionDiffResetMarker {
    static let manualPushItemID = "git.push.reset.marker"

    // Creates the hidden payload persisted after a successful manual push.
    static func text(branch: String, remote: String?) -> String {
        let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRemote = remote?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedRemote, !normalizedRemote.isEmpty, !normalizedBranch.isEmpty {
            return "Push completed on \(normalizedRemote)/\(normalizedBranch)."
        }
        if !normalizedBranch.isEmpty {
            return "Push completed on \(normalizedBranch)."
        }
        return "Push completed on remote."
    }

    // Keeps reset detection stable across persisted hidden markers and legacy visible messages.
    static func isResetMessage(_ message: CodexMessage) -> Bool {
        guard message.role == .system else { return false }
        if message.itemId == manualPushItemID {
            return true
        }

        let normalizedText = message.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedText.hasPrefix("push completed on ")
            || normalizedText.hasPrefix("commit & push completed.")
    }
}
