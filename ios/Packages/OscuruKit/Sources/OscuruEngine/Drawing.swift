import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension CIContext {
  /// Draws `image` over `bounds` into memory, and makes sure it was drawn. Core Image fails
  /// silently when the graphics processor will not draw (for an app in the background, or out of
  /// memory): the memory is left as it was, and a black picture would pass for the photo, be kept,
  /// and be shown from then on. The image is drawn opaque, so drawn memory has an alpha above zero
  /// everywhere; it is looked at in places over the whole area. The memory must start at zero.
  func draw(_ image: CIImage, into base: UnsafeMutableRawPointer, rowBytes: Int, bounds: CGRect, format: CIFormat, colorSpace: CGColorSpace?) throws {
    let width = Int(bounds.width.rounded())
    let height = Int(bounds.height.rounded())
    guard width > 0, height > 0 else { throw EngineError.renderFailed("there was nothing to draw") }
    // Bytes to a pixel, where its alpha is, and how wide.
    let layout: (pixel: Int, alpha: Int, size: Int)
    switch format {
    case .RGBA8: layout = (4, 3, 1)
    case .RGBAh: layout = (8, 6, 2)
    case .RGBAf: layout = (16, 12, 4)
    default: preconditionFailure("draw(_:into:) is for formats with alpha")
    }
    render(image.settingAlphaOne(in: bounds), toBitmap: base, rowBytes: rowBytes, bounds: bounds, format: format, colorSpace: colorSpace)
    let steps = 6
    for row in 0..<steps {
      for column in 0..<steps {
        let x = (width - 1) * column / (steps - 1)
        let y = (height - 1) * row / (steps - 1)
        let offset = y * rowBytes + x * layout.pixel + layout.alpha
        let drawn: Bool
        switch layout.size {
        case 1: drawn = base.load(fromByteOffset: offset, as: UInt8.self) != 0
        case 2: drawn = base.loadUnaligned(fromByteOffset: offset, as: UInt16.self) != 0
        default: drawn = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self) != 0
        }
        guard drawn else { throw EngineError.renderFailed("the picture was not drawn (the phone's graphics processor refused it)") }
      }
    }
  }

  /// The image as an opaque 8-bit picture in `space`, drawn now (see `draw(_:into:)`). Without a
  /// space, the values are drawn as they are, unconverted (a mask's).
  func picture(of image: CIImage, space: CGColorSpace?) throws -> CGImage {
    let extent = image.extent
    guard !extent.isInfinite else { throw EngineError.renderFailed("the picture has no edges") }
    let width = Int(extent.width.rounded())
    let height = Int(extent.height.rounded())
    guard width > 0, height > 0 else { throw EngineError.renderFailed("the picture is empty") }
    let rowBytes = width * 4
    var data = Data(count: rowBytes * height)
    try data.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { throw EngineError.renderFailed("there is no room for the picture") }
      try draw(
        image, into: base, rowBytes: rowBytes, bounds: CGRect(x: extent.minX, y: extent.minY, width: CGFloat(width), height: CGFloat(height)),
        format: .RGBA8, colorSpace: space)
    }
    guard let provider = CGDataProvider(data: data as CFData),
      let picture = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent)
    else { throw EngineError.renderFailed("the picture could not be kept") }
    return picture
  }
}

enum JPEG {
  /// A picture as a JPEG file's bytes, with its colour space's profile.
  static func data(of picture: CGImage, quality: Double) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw EngineError.renderFailed("the image could not be encoded")
    }
    let options = [kCGImageDestinationLossyCompressionQuality as String: min(1, max(0.1, quality))]
    CGImageDestinationAddImage(destination, picture, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw EngineError.renderFailed("the image could not be encoded") }
    return data as Data
  }
}
