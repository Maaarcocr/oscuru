import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import Foundation
import Vision

/// Segment Anything 2.1 (tiny), in Apple's Core ML conversion (apple/coreml-sam2.1-tiny, Apache-2.0):
/// the object at the points given. It only finds what is there; it never makes pixels. Three models:
/// the image encoder runs once per picture, then each set of points costs only the small prompt
/// encoder and mask decoder.
final class Segmenter {
  static let names = (encoder: "SAM2_1TinyImageEncoderFLOAT16", prompts: "SAM2_1TinyPromptEncoderFLOAT16", decoder: "SAM2_1TinyMaskDecoderFLOAT16")
  /// The square the image encoder takes; points are given in its coordinates.
  static let inputSide = 1024.0

  struct Encoding {
    let embedding: MLMultiArray
    let s0: MLMultiArray
    let s1: MLMultiArray
  }

  /// A mask's logits: above 0 is the object. `side` by `side`, rows from the top, over the whole
  /// picture (stretched to a square as the encoder saw it).
  struct Logits {
    let values: [Float]
    let side: Int
  }

  private let encoder: MLModel
  private let prompts: MLModel
  private let decoder: MLModel

  /// Loads the models from `folder` (see `Models.load`).
  init(folder: URL) throws {
    encoder = try Models.load(Segmenter.names.encoder, from: folder)
    prompts = try Models.load(Segmenter.names.prompts, from: folder)
    decoder = try Models.load(Segmenter.names.decoder, from: folder)
  }

  /// Reads a picture once, for any number of selections in it.
  func encode(_ image: CGImage) throws -> Encoding {
    guard let constraint = encoder.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
      throw EngineError.renderFailed("the segmentation model takes no image")
    }
    // Stretched to the square, as the model was trained.
    let value = try MLFeatureValue(
      cgImage: image, constraint: constraint, options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
    let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value]))
    guard let embedding = output.featureValue(for: "image_embedding")?.multiArrayValue,
      let s0 = output.featureValue(for: "feats_s0")?.multiArrayValue,
      let s1 = output.featureValue(for: "feats_s1")?.multiArrayValue
    else { throw EngineError.renderFailed("the segmentation model gave no encoding") }
    return Encoding(embedding: embedding, s0: s0, s1: s1)
  }

  /// The object at `points`, without what is at `exclude`; points are fractions of the picture
  /// from its top-left corner.
  func select(_ encoding: Encoding, points: [[Double]], exclude: [[Double]]) throws -> Logits {
    let all = points.map { ($0, Float(1)) } + exclude.map { ($0, Float(0)) }
    let coordinates = try MLMultiArray(shape: [1, NSNumber(value: all.count), 2], dataType: .float32)
    let labels = try MLMultiArray(shape: [1, NSNumber(value: all.count)], dataType: .float32)
    for (index, (point, label)) in all.enumerated() {
      coordinates[[0, NSNumber(value: index), 0]] = NSNumber(value: Float(point[0] * Segmenter.inputSide))
      coordinates[[0, NSNumber(value: index), 1]] = NSNumber(value: Float(point[1] * Segmenter.inputSide))
      labels[[0, NSNumber(value: index)]] = NSNumber(value: label)
    }
    let prompt = try prompts.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": coordinates, "labels": labels]))
    guard let sparse = prompt.featureValue(for: "sparse_embeddings")?.multiArrayValue,
      let dense = prompt.featureValue(for: "dense_embeddings")?.multiArrayValue
    else { throw EngineError.renderFailed("the segmentation model could not read the points") }
    let decoded = try decoder.prediction(
      from: MLDictionaryFeatureProvider(dictionary: [
        "image_embedding": encoding.embedding, "sparse_embedding": sparse, "dense_embedding": dense, "feats_s0": encoding.s0,
        "feats_s1": encoding.s1,
      ]))
    guard let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue, let scores = decoded.featureValue(for: "scores")?.multiArrayValue
    else { throw EngineError.renderFailed("the segmentation model gave no mask") }
    // Of the three candidates, the one the model rates best.
    let candidates = masks.shape[1].intValue
    var best = 0
    for index in 1..<candidates where scores[[0, NSNumber(value: index)]].floatValue > scores[[0, NSNumber(value: best)]].floatValue {
      best = index
    }
    let side = masks.shape[2].intValue
    var values = [Float](repeating: 0, count: side * side)
    let chosen = NSNumber(value: best)
    for row in 0..<side {
      for column in 0..<side {
        values[row * side + column] = masks[[0, chosen, NSNumber(value: row), NSNumber(value: column)]].floatValue
      }
    }
    return Logits(values: values, side: side)
  }
}

extension Effects {
  /// A selection as a grey mask over `frame`: the logits stretched back to the frame's shape, with an
  /// edge about one logit wide, so it is crisp at any size but never jagged.
  static func objectMask(_ logits: Segmenter.Logits, frame: CGRect) -> CIImage {
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frame)
    let side = logits.side
    // 0.5 at the edge; ±16 logits reach black and white.
    var bytes = [UInt8](repeating: 0, count: side * side)
    for index in bytes.indices {
      bytes[index] = UInt8(max(0, min(255, ((logits.values[index] / 32 + 0.5) * 255).rounded())))
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let picture = CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent)
    else { return black }
    let scaled = CIImage(cgImage: picture, options: [.colorSpace: NSNull()])
      .clampedToExtent()
      .samplingLinear()
      .transformed(by: CGAffineTransform(scaleX: frame.width / CGFloat(side), y: frame.height / CGFloat(side)))
      .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
    let edge = CIFilter.colorMatrix()
    edge.inputImage = scaled
    edge.rVector = CIVector(x: 16, y: 0, z: 0, w: 0)
    edge.biasVector = CIVector(x: -7.5, y: 0, z: 0, w: 1)
    let clamp = CIFilter.colorClamp()
    clamp.inputImage = edge.outputImage
    clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
    clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
    return opaque(clamp.outputImage ?? black).cropped(to: frame)
  }
}
