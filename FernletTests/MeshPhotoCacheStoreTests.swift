import Foundation
import UIKit
import Testing
@testable import Fernlet

@MainActor
struct MeshPhotoCacheStoreTests {
    private func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // output pixels == size, so dimensions are deterministic
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.5)!
    }

    /// Regression for prior finding #11: normally-sized photos are accepted.
    @Test func acceptsNormallySizedImage() {
        #expect(MeshPhotoCacheStore.isWithinSafePixelBounds(jpeg(width: 300, height: 300)))
    }

    /// A photo whose pixel dimensions exceed the safe bound is rejected *before* its
    /// full-resolution bytes are persisted or decoded by any display/library-save sink — the
    /// 10 MB byte cap alone cannot stop a tiny, highly-compressed image that decodes huge.
    @Test func rejectsOverlyLargeDimensions() {
        // 7000 px wide is over the 6000 px cap but trivially small in bytes/memory.
        #expect(!MeshPhotoCacheStore.isWithinSafePixelBounds(jpeg(width: 7000, height: 4)))
    }

    /// Data whose dimensions cannot be read (non-image / malformed) is treated as unsafe.
    @Test func rejectsNonImageData() {
        #expect(!MeshPhotoCacheStore.isWithinSafePixelBounds(Data("not an image".utf8)))
    }
}
