import UIKit
import FernletDomainModel

extension UIImage {
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

    func friendPhotoThumbnailData(maxDimension: CGFloat = 320) -> Data? {
        resizedForFriendSharing(maxDimension: maxDimension).jpegData(compressionQuality: 0.72)
    }
}
