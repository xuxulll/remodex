// FILE: TurnComposerModels.swift
// Purpose: Shared composer draft and attachment models used by service and view layers.
// Layer: Model
// Exports: TurnComposerImageAttachment, TurnComposerImageAttachmentState, QueuedTurnDraft, QueuePauseState
// Depends on: Foundation, CodexImageAttachment, CodexCollaboration

import Foundation

struct TurnComposerImageAttachment: Identifiable {
    let id: String
    var state: TurnComposerImageAttachmentState
}

enum TurnComposerImageAttachmentState: Equatable {
    case loading
    case ready(CodexImageAttachment)
    case failed
}

struct TurnComposerMentionedFile: Identifiable, Equatable {
    let id = UUID().uuidString
    let fileName: String
    let path: String
}

struct TurnComposerMentionedSkill: Identifiable, Equatable {
    let id = UUID().uuidString
    let name: String
    let path: String?
    let description: String?
}

struct QueuedTurnDraft: Identifiable {
    let id: String
    let text: String
    let attachments: [CodexImageAttachment]
    let skillMentions: [CodexTurnSkillMention]
    // Preserves special send semantics, such as plan mode, while a busy thread queues locally.
    let collaborationMode: CodexCollaborationModeKind?
    // Preserves the original composer state so a queued row can move back into the input intact.
    let rawInput: String
    let rawFileMentions: [TurnComposerMentionedFile]
    let rawSkillMentions: [TurnComposerMentionedSkill]
    let rawAttachments: [TurnComposerImageAttachment]
    let rawSubagentsSelectionArmed: Bool
    let createdAt: Date

    init(
        id: String,
        text: String,
        attachments: [CodexImageAttachment],
        skillMentions: [CodexTurnSkillMention],
        collaborationMode: CodexCollaborationModeKind?,
        rawInput: String? = nil,
        rawFileMentions: [TurnComposerMentionedFile] = [],
        rawSkillMentions: [TurnComposerMentionedSkill] = [],
        rawAttachments: [TurnComposerImageAttachment] = [],
        rawSubagentsSelectionArmed: Bool = false,
        createdAt: Date
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.skillMentions = skillMentions
        self.collaborationMode = collaborationMode
        self.rawInput = rawInput ?? text
        self.rawFileMentions = rawFileMentions
        self.rawSkillMentions = rawSkillMentions
        self.rawAttachments = rawAttachments
        self.rawSubagentsSelectionArmed = rawSubagentsSelectionArmed
        self.createdAt = createdAt
    }
}

enum QueuePauseState: Equatable {
    case active
    case paused(errorMessage: String)
}
