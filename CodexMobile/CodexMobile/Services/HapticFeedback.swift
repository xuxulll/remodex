// FILE: HapticFeedback.swift
// Purpose: Centralized haptic feedback utility for premium button interactions.
// Layer: Service
// Exports: HapticFeedback
// Depends on: UIKit

#if os(iOS)
#if os(iOS)
import UIKit
#endif
#endif

class HapticFeedback {
    enum NotificationFeedbackType {
        case success
        case warning
        case error
    }

    enum ImpactFeedbackStyle {
        case light
        case medium
        case heavy
        case soft
        case rigid
    }

    static let shared = HapticFeedback()

    private init() {}

    // Uses the system notification generator for stateful success/failure cues.
    func triggerNotificationFeedback(type: NotificationFeedbackType = .success) {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(uiKitNotificationType(for: type))
        #endif
    }

    func triggerImpactFeedback(style: ImpactFeedbackStyle = .medium) {
        #if os(iOS)
        let resolvedStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case .light:
            resolvedStyle = .light
        case .medium:
            resolvedStyle = .medium
        case .heavy:
            resolvedStyle = .heavy
        case .soft:
            resolvedStyle = .soft
        case .rigid:
            resolvedStyle = .rigid
        }

        let generator = UIImpactFeedbackGenerator(style: resolvedStyle)
        generator.impactOccurred()
        #endif
    }

    #if os(iOS)
    private func uiKitNotificationType(
        for type: NotificationFeedbackType
    ) -> UINotificationFeedbackGenerator.FeedbackType {
        switch type {
        case .success:
            return .success
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }
    #endif
}
