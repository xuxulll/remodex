// FILE: PlatformColorCompatibility.swift
// Purpose: Maps common UIKit semantic color names to macOS equivalents so shared views compile cross-platform.
// Layer: View Shared Support

#if os(macOS)
import AppKit

extension NSColor {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var placeholderText: NSColor { .placeholderTextColor }

    static var systemBackground: NSColor { .windowBackgroundColor }
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemBackground: NSColor { .underPageBackgroundColor }

    static var separator: NSColor { .separatorColor }

    static var systemGray2: NSColor { .systemGray }
    static var systemGray3: NSColor { .systemGray }
    static var systemGray4: NSColor { .systemGray }
    static var systemGray5: NSColor { .systemGray }
    static var systemRed: NSColor { .systemRed }
    static var systemGreen: NSColor { .systemGreen }
    static var systemBlue: NSColor { .systemBlue }
}
#endif
