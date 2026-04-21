// FILE: TurnImagePreview.swift
// Purpose: Reusable fullscreen image preview for timeline media.
// Layer: View Support
// Exports: PreviewImagePayload, ZoomableImagePreviewScreen, ImageSaveCoordinator

import SwiftUI
#if os(iOS)
#if os(iOS)
import UIKit
#endif
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
typealias PreviewPlatformImage = UIImage
#elseif os(macOS)
typealias PreviewPlatformImage = NSImage
#endif

struct PreviewImagePayload: Identifiable {
    let id: String
    let image: PreviewPlatformImage
    var title: String? = nil

    init(id: String = UUID().uuidString, image: PreviewPlatformImage, title: String? = nil) {
        self.id = id
        self.image = image
        self.title = title
    }
}

struct ZoomableImagePreviewScreen: View {
    let payload: PreviewImagePayload
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.92).ignoresSafeArea()
            imageView
                .padding(24)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(AppFont.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
        }
    }

    private var imageView: some View {
        #if os(iOS)
        Image(uiImage: payload.image)
            .resizable()
            .scaledToFit()
        #elseif os(macOS)
        Image(nsImage: payload.image)
            .resizable()
            .scaledToFit()
        #endif
    }
}

final class ImageSaveCoordinator: NSObject {
    func save(_ image: PreviewPlatformImage, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}
