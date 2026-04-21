// FILE: TurnMermaidRenderer.swift
// Purpose: Detects fenced Mermaid blocks and renders safe cross-platform placeholders.
// Layer: View Support
// Exports: MermaidMarkdownContent, MermaidMarkdownSegment, MermaidMarkdownContentCache, MermaidMarkdownContentView

import Foundation
import SwiftUI

struct MermaidMarkdownContent {
    let segments: [MermaidMarkdownSegment]

    var hasMermaidBlocks: Bool {
        segments.contains { $0.kind.isMermaid }
    }
}

struct MermaidMarkdownSegment: Identifiable {
    enum Kind {
        case markdown(String)
        case mermaid(String)

        var isMermaid: Bool {
            if case .mermaid = self {
                return true
            }
            return false
        }
    }

    let id: String
    let kind: Kind
}

enum MermaidMarkdownContentCache {
    static let maxEntries = 256
    static let lock = NSLock()
    static var contentByKey: [String: MermaidMarkdownContent?] = [:]

    static func content(messageID: String, text: String) -> MermaidMarkdownContent? {
        let cacheKey = TurnTextCacheKey.key(messageID: messageID, kind: "mermaid-markdown", text: text)

        lock.lock()
        if let cached = contentByKey[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = MermaidMarkdownParser.parse(text)

        lock.lock()
        if contentByKey.count >= maxEntries {
            contentByKey.removeAll(keepingCapacity: true)
        }
        contentByKey[cacheKey] = parsed
        lock.unlock()

        return parsed
    }

    static func reset() {
        lock.lock()
        contentByKey.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    static func resetRenderedSnapshots() {
        // No-op in the cross-platform placeholder renderer.
    }
}

struct MermaidMarkdownContentView: View {
    let content: MermaidMarkdownContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(content.segments) { segment in
                switch segment.kind {
                case .markdown(let text):
                    MarkdownTextView(text: text, profile: .assistantProse)
                case .mermaid(let source):
                    MermaidPlaceholderBlock(source: source)
                }
            }
        }
    }
}

private struct MermaidPlaceholderBlock: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Mermaid diagram", systemImage: "chart.xyaxis.line")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)

            Text(source)
                .font(AppFont.mono(.caption))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private enum MermaidMarkdownParser {
    static func parse(_ text: String) -> MermaidMarkdownContent? {
        guard text.contains("```mermaid") else {
            return nil
        }

        var segments: [MermaidMarkdownSegment] = []
        var cursor = text.startIndex

        while cursor < text.endIndex,
              let fenceRange = text[cursor...].range(of: "```mermaid") {
            let prefix = String(text[cursor..<fenceRange.lowerBound])
            if !prefix.isEmpty {
                segments.append(
                    MermaidMarkdownSegment(
                        id: UUID().uuidString,
                        kind: .markdown(prefix)
                    )
                )
            }

            let codeStart = fenceRange.upperBound
            guard let codeEnd = text[codeStart...].range(of: "```") else {
                let remainder = String(text[fenceRange.lowerBound...])
                segments.append(MermaidMarkdownSegment(id: UUID().uuidString, kind: .markdown(remainder)))
                cursor = text.endIndex
                break
            }

            var mermaidSource = String(text[codeStart..<codeEnd.lowerBound])
            if mermaidSource.hasPrefix("\n") {
                mermaidSource.removeFirst()
            }
            mermaidSource = mermaidSource.trimmingCharacters(in: .whitespacesAndNewlines)

            segments.append(
                MermaidMarkdownSegment(
                    id: UUID().uuidString,
                    kind: .mermaid(mermaidSource)
                )
            )

            cursor = codeEnd.upperBound
        }

        if cursor < text.endIndex {
            let tail = String(text[cursor...])
            if !tail.isEmpty {
                segments.append(
                    MermaidMarkdownSegment(
                        id: UUID().uuidString,
                        kind: .markdown(tail)
                    )
                )
            }
        }

        guard !segments.isEmpty else {
            return nil
        }

        return MermaidMarkdownContent(segments: segments)
    }
}
