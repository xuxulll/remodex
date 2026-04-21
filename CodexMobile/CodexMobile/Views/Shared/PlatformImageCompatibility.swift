// FILE: PlatformImageCompatibility.swift
// Purpose: Provides UIImage compatibility APIs for shared SwiftUI views on macOS.

#if os(macOS)
import AppKit
import SwiftUI

typealias UIImage = NSImage

extension Image {
    init(uiImage: NSImage) {
        self.init(nsImage: uiImage)
    }
}
#endif
