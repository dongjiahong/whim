import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum QRCodeHelper {
    private static let context = CIContext()

    static func generate(from string: String, size: CGFloat = 180) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaleX = size / output.extent.size.width
        let scaleY = size / output.extent.size.height
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
