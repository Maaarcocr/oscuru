import Accelerate
import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import OscuruCore
import Vision

/// Depth Anything V2 (small), in Apple's Core ML conversion (apple/coreml-depth-anything-v2-small,
/// Apache-2.0): how far each part of a photo is, estimated from the picture alone. It only measures
/// what is there; it never makes pixels.
final class DepthEstimator {
  static let name = "DepthAnythingV2SmallF16P8"

  private let model: MLModel
  /// One prediction at a time: photos render at the same time, and share the model.
  private let lock = NSLock()

  /// Loads the model from `folder` (see `Models.load`).
  init(folder: URL) throws {
    model = try Models.load(DepthEstimator.name, from: folder)
  }

  /// The picture's depth, from nearest (0) to farthest (1). The model takes a fixed shape, so the
  /// picture is stretched to it, as the model was evaluated; the map is stretched back by whoever draws it.
  func depth(of image: CGImage) throws -> DepthMap {
    lock.lock()
    defer { lock.unlock() }
    guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
      throw EngineError.renderFailed("the depth model takes no image")
    }
    let value = try MLFeatureValue(
      cgImage: image, constraint: constraint, options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
    let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value]))
    guard let buffer = output.featureValue(for: "depth")?.imageBufferValue else {
      throw EngineError.renderFailed("the depth model gave no depth")
    }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer), width > 0, height > 0 else {
      throw EngineError.renderFailed("the depth model gave an empty depth map")
    }
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    var values = [Float](repeating: 0, count: width * height)
    switch CVPixelBufferGetPixelFormatType(buffer) {
    case kCVPixelFormatType_OneComponent16Half:
      let converted = values.withUnsafeMutableBytes { out -> vImage_Error in
        var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        var target = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        return vImageConvert_Planar16FtoPlanarF(&source, &target, vImage_Flags(kvImageNoFlags))
      }
      guard converted == kvImageNoError else { throw EngineError.renderFailed("the depth map could not be read") }
    case kCVPixelFormatType_OneComponent32Float:
      for row in 0..<height {
        let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: Float.self)
        for column in 0..<width { values[row * width + column] = line[column] }
      }
    default:
      throw EngineError.renderFailed("the depth map came in an unexpected format")
    }
    return DepthMap(inverseDepth: values, width: width, height: height)
  }
}

/// The on-device models this build carries (see scripts/fetch-models.sh).
enum Models {
  /// A model from `folder`: compiled (`.mlmodelc`) when the app was built with it, otherwise its
  /// package (`.mlpackage`), compiled here first.
  static func load(_ name: String, from folder: URL) throws -> MLModel {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let compiled = folder.appendingPathComponent("\(name).mlmodelc")
    if FileManager.default.fileExists(atPath: compiled.path) {
      return try MLModel(contentsOf: compiled, configuration: configuration)
    }
    let package = folder.appendingPathComponent("\(name).mlpackage")
    guard FileManager.default.fileExists(atPath: package.path) else {
      throw EngineError.renderFailed("the model \(name) is not in this build")
    }
    return try MLModel(contentsOf: try MLModel.compileModel(at: package), configuration: configuration)
  }
}

extension Effects {
  /// A depth map as a grey image over `extent`: the band's weight at each point, or without a band
  /// the distance itself (black nearest, white farthest). Stretched back to the picture's shape and
  /// smoothed between the map's points.
  static func depthImage(_ map: DepthMap, band: ValueRange?, extent: CGRect) -> CIImage {
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
    let bytes = map.greys(in: band)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let picture = CGImage(
        width: map.width, height: map.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: map.width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent)
    else { return black }
    let scaled = CIImage(cgImage: picture, options: [.colorSpace: NSNull()])
      .clampedToExtent()
      .samplingLinear()
      .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(map.width), y: extent.height / CGFloat(map.height)))
      .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    return opaque(scaled).cropped(to: extent)
  }
}
