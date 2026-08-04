import UIKit
import FernletDomainModel

/// Outbound-photo sizing helpers for the friend photowall.
///
/// Used by `MeshNetworkManager` to normalize the user's OWN photo before it is shared over the
/// mesh — keeping outgoing images well under the receiving side's decompression-bomb bounds
/// (peers reject anything near ``PrivateMediaStore``'s pixel caps, so senders downscale first).
extension UIImage {
    /// Returns the image downscaled so its longest side is at most `maxDimension` points
    /// (rendered at 1x, so points equal pixels); images already within the cap are returned as-is.
    public func resizedForFriendSharing(maxDimension: CGFloat = 1400) -> UIImage {
        let largestSide = max(size.width, size.height)
        guard largestSide > maxDimension else { return self }
        let scale = maxDimension / largestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // output pixels == targetSize pts; prevents 2x/3x device upscaling
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Downscales to thumbnail size and JPEG-encodes, for a compact friend-photo preview.
    /// (Currently uncalled; kept alongside ``resizedForFriendSharing(maxDimension:)``.)
    func friendPhotoThumbnailData(maxDimension: CGFloat = 320) -> Data? {
        resizedForFriendSharing(maxDimension: maxDimension).jpegData(compressionQuality: 0.72)
    }
}
