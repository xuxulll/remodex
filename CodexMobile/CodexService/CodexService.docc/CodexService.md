# ``CodexService``

Codex communication and runtime framework used by Remodex (iOS/macOS) and RemodexMac.

## Overview

`CodexService` is the shared integration layer between the app UI and Codex runtime/bridge endpoints.
It centralizes:

- Transport and connection lifecycle (local bridge, relay, secure channel).
- Thread/turn/message synchronization and timeline reconciliation.
- Runtime capabilities (model list, approvals, plan mode, voice, review, git actions).
- Persistence for message history and AI change sets.
- Shared parser/model infrastructure used by both service and UI layers.

The primary state owner is `CodexService` (`@MainActor`, `@Observable`), with behavior split across focused extension files in `Services/`.

## Module Layout

### Core Service

- `Services/CodexService.swift`: canonical state container and initialization.
- `Services/CodexService+*.swift`: transport, incoming payload handling, sync, history, account, threads/turns, notifications, review, runtime config, secure transport, voice, and helpers.
- `Services/CodexServiceError.swift`: typed service errors.

### Persistence and Security

- `Services/CodexMessagePersistence.swift`
- `Services/AIChangeSetPersistence.swift`
- `Services/SecureStore.swift`
- `Services/CodexSecureTransportModels.swift`

### Shared Models and Parsing

- `Models/Codex*.swift`, `Models/RPCMessage.swift`, `Models/JSONValue.swift`
- Timeline and content parsing:
  - `Models/TurnTimelineReducer.swift`
  - `Models/ThinkingDisclosureParser.swift`
  - `Models/TurnFileChangeSummaryParser.swift`
  - `Models/TurnMessageRegexCache.swift`
  - `Models/TurnSessionDiffResetMarker.swift`

### Bridge Runtime (macOS-only shell execution)

- `Services/BridgeControlService.swift`
- `Models/BridgeControlModels.swift`

`BridgeControlService` is compiled only on macOS (`#if os(macOS)`), so shell-command runtime control is not part of iOS builds.

## Platform Behavior

- iOS:
  - Uses shared service/runtime APIs.
  - Does not compile shell-command bridge runtime implementation.
- macOS:
  - Uses the same service APIs.
  - Includes bridge runtime control and shell-command orchestration via `BridgeControlService`.

## Integration Guidance

- Instantiate one `CodexService` per app process/session boundary.
- Keep UI logic outside the framework; bind views/view-models to `CodexService` state.
- Treat bridge/runtime control as capability-driven:
  - macOS may invoke bridge runtime management.
  - iOS should rely on runtime availability and transport state from `CodexService`.

## Notes

- This framework is local-first and intended for Remodex clients.
- Avoid adding UI-specific dependencies into `CodexService`; keep shared parser/model logic here and UI rendering in app targets.
