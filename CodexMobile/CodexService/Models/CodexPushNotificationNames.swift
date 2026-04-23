// FILE: CodexPushNotificationNames.swift
// Purpose: Shared push registration notification names consumed by app delegate and service.
// Layer: Model
// Exports: Notification.Name push registration helpers
// Depends on: Foundation

import Foundation

extension Notification.Name {
    static let codexDidRegisterForRemoteNotifications = Notification.Name("codex.didRegisterForRemoteNotifications")
    static let codexDidFailToRegisterForRemoteNotifications = Notification.Name("codex.didFailToRegisterForRemoteNotifications")
}
