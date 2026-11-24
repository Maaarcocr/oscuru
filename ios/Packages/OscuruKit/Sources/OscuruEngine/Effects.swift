import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import OscuruCore
import Vision

/// Grain, halation, masks and local adjustments. All of it is ordinary image processing with
/// Core Image, plus Vision's on-device analysis to find the subject or people; nothing here
/// generates image content.
enum Effects {
  private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

  // MARK: Halation

  /// A red-orange glow spreading from the bright parts of the photo, screened on top of it.
  static func halation(_ image: CIImage, _ halation: RenderRecipe.Halation, edge: CGFloat) -> CIImage {
    let extent = image.extent
    let t = CGFloat(halation.threshold)
    let span = max(0.02, 1 - t)
    // How far above the threshold each pixel's luminance is, 0 to 1, in every channel.
    let lift = CIFilter.colorMatrix()
    lift.inputImage = image
    let weights = CIVector(x: 0.2126 / span, y: 0.7152 / span, z: 0.0722 / span, w: 0)
    lift.rVector = weights
    lift.gVector = weights
    lift.bVector = weights
    lift.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    lift.biasVector = CIVector(x: -t / span, y: -t / span, z: -t / span, w: 1)
    let clamp = CIFilter.colorClamp()
    clamp.inputImage = lift.outputImage
    clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
    clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
    // Tinted and scaled by strength.
    let tint = CIFilter.colorMatrix()
    tint.inputImage = clamp.outputImage
    let strength = CGFloat(halation.strength)
    tint.rVector = CIVector(x: CGFloat(halation.color[0]) * strength, y: 0, z: 0, w: 0)
    tint.gVector = CIVector(x: 0, y: CGFloat(halation.color[1]) * strength, z: 0, w: 0)
    tint.bVector = CIVector(x: 0, y: 0, z: CGFloat(halation.color[2]) * strength, w: 0)
    tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    guard let bright = tint.outputImage else { return image }
    let blur = CIFilter.gaussianBlur()
    blur.inputImage = bright.clampedToExtent()
    blur.radius = Float(max(1, CGFloat(halation.radius) * edge))
    guard let glow = blur.outputImage?.cropped(to: extent) else { return image }
    let screen = CIFilter.screenBlendMode()
    screen.inputImage = glow
    screen.backgroundImage = image
    return (screen.outputImage ?? image).cropped(to: extent)
  }

  // MARK: Grain

  /// Monochrome grain over the finished frame, strongest in the midtones like film's. The pattern
  /// is fixed, so a photo renders the same every time; its size follows the frame, so a preview
  /// looks like a smaller copy of the export.
  static func grain(_ image: CIImage, _ grain: RenderRecipe.Grain) -> CIImage {
    let extent = image.extent
    let pixels = CGFloat(grain.size) * max(extent.width, extent.height)
    // Grains finer than a pixel average out, as they would in a downscaled export.
    let scale = max(1, pixels)
    let strength = CGFloat(grain.strength) * min(1, pixels)
    let roughness = CGFloat(grain.roughness)
    guard let fine = noise(scale: scale, weight: strength * (1 - 0.6 * roughness), offset: .zero, extent: extent),
      let coarse = noise(scale: scale * 2.5, weight: strength * 0.9 * roughness, offset: CGPoint(x: 517, y: 313), extent: extent)
    else { return image }
    let sum = CIFilter.additionCompositing()
    sum.inputImage = coarse
    sum.backgroundImage = fine
    // Centred on mid-grey: overlay then changes midtones most and black and white least.
    let grey = CIFilter.colorMatrix()
    grey.inputImage = sum.outputImage
    grey.biasVector = CIVector(x: 0.5, y: 0.5, z: 0.5, w: 1)
    grey.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    guard let texture = grey.outputImage?.cropped(to: extent) else { return image }

    // In encoded values, so the grain reads the same from shadows to highlights.
    let encode = CIFilter.linearToSRGBToneCurve()
    encode.inputImage = image
    let overlay = CIFilter.overlayBlendMode()
    overlay.inputImage = texture
    overlay.backgroundImage = encode.outputImage
    let decode = CIFilter.sRGBToneCurveToLinear()
    decode.inputImage = overlay.outputImage
    return (decode.outputImage ?? image).cropped(to: extent)
  }

  /// Zero-centred grey noise with grains `scale` pixels across, its standard deviation about `weight`.
  private static func noise(scale: CGFloat, weight: CGFloat, offset: CGPoint, extent: CGRect) -> CIImage? {
    guard let random = CIFilter.randomGenerator().outputImage else { return nil }
    // The generator's alpha is random too. Made opaque first, its colours are the uniform values
    // themselves; otherwise reading them divides by that alpha and biases the grain bright.
    let grains = random.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
      .cropped(to: extent)
      .settingAlphaOne(in: extent)
    // One channel of uniform noise (standard deviation 0.29) to every channel, centred on 0.
    let gain = weight / 0.29
    let matrix = CIFilter.colorMatrix()
    matrix.inputImage = grains
    let pick = CIVector(x: 0, y: gain, z: 0, w: 0)
    matrix.rVector = pick
    matrix.gVector = pick
    matrix.bVector = pick
    matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    matrix.biasVector = CIVector(x: -0.5 * gain, y: -0.5 * gain, z: -0.5 * gain, w: 1)
    return matrix.outputImage
  }

  // MARK: Local adjustments

  /// One local adjustment: the whole frame adjusted, then blended through the mask.
  static func local(_ pass: RenderRecipe.LocalPass, to image: CIImage, mask: CIImage, edge: CGFloat) -> CIImage {
    let extent = image.extent
    var adjusted = image
    if let gains = pass.gains {
      let balance = CIFilter.colorMatrix()
      balance.inputImage = adjusted
      balance.rVector = CIVector(x: CGFloat(gains[0]), y: 0, z: 0, w: 0)
      balance.gVector = CIVector(x: 0, y: CGFloat(gains[1]), z: 0, w: 0)
      balance.bVector = CIVector(x: 0, y: 0, z: CGFloat(gains[2]), w: 0)
      adjusted = balance.outputImage ?? adjusted
    }
    if pass.toneTableSize >= 2, pass.toneTable.count == pass.toneTableSize * 3 * MemoryLayout<Float32>.size {
      let tone = CIFilter.colorCurves()
      tone.inputImage = adjusted
      tone.curvesData = pass.toneTable
      tone.curvesDomain = CIVector(x: 0, y: 1)
      tone.colorSpace = displayP3
      adjusted = tone.outputImage ?? adjusted
    }
    if pass.saturation != 1 {
      let controls = CIFilter.colorControls()
      controls.inputImage = adjusted
      controls.saturation = Float(pass.saturation)
      controls.brightness = 0
      controls.contrast = 1
      adjusted = controls.outputImage ?? adjusted
    }
    if pass.clarity != 0 {
      let clarity = CIFilter.unsharpMask()
      clarity.inputImage = adjusted.clampedToExtent()
      clarity.radius = Float(RenderRecipe.clarityRadius * Double(edge))
      clarity.intensity = Float(pass.clarity)
      adjusted = (clarity.outputImage ?? adjusted).cropped(to: extent)
    }
    let blend = CIFilter.blendWithMask()
    blend.inputImage = adjusted
    blend.backgroundImage = image
    blend.maskImage = mask
    return (blend.outputImage ?? image).cropped(to: extent)
  }

  /// Where a mask applies, as a grey image over the frame (`base`'s extent): 1 fully, 0 not at all.
  /// `base` is the photo the ranges are measured on; `found` gives the subject or people mask, in
  /// the frame's coordinates, when the area needs one.
  static func mask(_ mask: Mask, over base: CIImage, found: (String) -> CIImage?) -> CIImage {
    let frame = base.extent
    var area = self.area(mask.area, frame: frame, found: found)
    if mask.invert { area = invert(area) }
    if let cube = ColorPipeline.rangeMaskCube(luminance: mask.luminance, color: mask.color) {
      let ranges = CIFilter.colorCubeWithColorSpace()
      ranges.inputImage = base
      ranges.cubeDimension = Float(ColorPipeline.cubeSize)
      ranges.cubeData = cube.withUnsafeBufferPointer { Data(buffer: $0) }
      ranges.colorSpace = displayP3
      // The cube's weights come out as encoded Display P3 greys; re-encoding brings back the weights themselves.
      let weights = CIFilter.linearToSRGBToneCurve()
      weights.inputImage = ranges.outputImage
      if let weight = weights.outputImage {
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = weight
        multiply.backgroundImage = area
        area = multiply.outputImage ?? area
      }
    }
    return opaque(area).cropped(to: frame)
  }

  private static func area(_ area: MaskArea, frame: CGRect, found: (String) -> CIImage?) -> CIImage {
    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: frame)
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frame)
    let width = frame.width
    let height = frame.height
    switch area.type {
    case "radial":
      // A circle in a unit square, stretched to the ellipse, turned, and moved to its centre.
      let unit: CGFloat = 1000
      let gradient = CIFilter.radialGradient()
      gradient.center = CGPoint(x: unit / 2, y: unit / 2)
      gradient.radius0 = Float(unit / 2 * max(0, 1 - CGFloat(area.feather)) - 0.5)
      gradient.radius1 = Float(unit / 2)
      gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
      gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
      guard let circle = gradient.outputImage else { return black }
      let transform = CGAffineTransform(translationX: -unit / 2, y: -unit / 2)
        .concatenating(CGAffineTransform(scaleX: CGFloat(area.width) * width / unit, y: CGFloat(area.height) * height / unit))
        // Clockwise on screen is negative in Core Image, whose y axis points up.
        .concatenating(CGAffineTransform(rotationAngle: -CGFloat(area.angle) * .pi / 180))
        .concatenating(CGAffineTransform(translationX: frame.minX + CGFloat(area.x) * width, y: frame.minY + (1 - CGFloat(area.y)) * height))
      return circle.transformed(by: transform).cropped(to: frame)
    case "linear":
      let gradient = CIFilter.linearGradient()
      gradient.point0 = CGPoint(x: frame.minX + CGFloat(area.from[0]) * width, y: frame.minY + (1 - CGFloat(area.from[1])) * height)
      gradient.point1 = CGPoint(x: frame.minX + CGFloat(area.to[0]) * width, y: frame.minY + (1 - CGFloat(area.to[1])) * height)
      gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
      gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
      return gradient.outputImage?.cropped(to: frame) ?? black
    case "subject", "people":
      return found(area.type)?.cropped(to: frame) ?? black
    default:
      return white
    }
  }

  private static func invert(_ image: CIImage) -> CIImage {
    let matrix = CIFilter.colorMatrix()
    matrix.inputImage = image
    matrix.rVector = CIVector(x: -1, y: 0, z: 0, w: 0)
    matrix.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
    matrix.bVector = CIVector(x: 0, y: 0, z: -1, w: 0)
    matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    matrix.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
    return matrix.outputImage ?? image
  }

  /// The first channel to every channel, fully opaque: masks are read as greys.
  static func opaque(_ image: CIImage) -> CIImage {
    let matrix = CIFilter.colorMatrix()
    matrix.inputImage = image
    let first = CIVector(x: 1, y: 0, z: 0, w: 0)
    matrix.rVector = first
    matrix.gVector = first
    matrix.bVector = first
    matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
    return matrix.outputImage ?? image
  }

  /// The photo with a mask painted red over it, for showing what a mask covers.
  static func overlay(_ image: CIImage, mask: CIImage) -> CIImage {
    let extent = image.extent
    let red = CIImage(color: CIColor(red: 1, green: 0.12, blue: 0.08)).cropped(to: extent)
    let soften = CIFilter.colorMatrix()
    soften.inputImage = mask
    soften.rVector = CIVector(x: 0.6, y: 0, z: 0, w: 0)
    soften.gVector = CIVector(x: 0, y: 0.6, z: 0, w: 0)
    soften.bVector = CIVector(x: 0, y: 0, z: 0.6, w: 0)
    let blend = CIFilter.blendWithMask()
    blend.inputImage = red
    blend.backgroundImage = image
    blend.maskImage = soften.outputImage
    return (blend.outputImage ?? image).cropped(to: extent)
  }

  // MARK: Finding the subject and people

  /// The main subjects, from Vision's foreground instance mask, as a grey image the size of `image`.
  /// Nil when Vision finds none or cannot run.
  static func findSubject(in image: CGImage) -> CIImage? {
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let request = VNGenerateForegroundInstanceMaskRequest()
    do {
      try handler.perform([request])
      guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
      let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
      return fitted(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]), to: image)
    } catch {
      return nil
    }
  }

  /// Every person, from Vision's person segmentation, as a grey image the size of `image`.
  static func findPeople(in image: CGImage) -> CIImage? {
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .accurate
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    do {
      try handler.perform([request])
      guard let buffer = request.results?.first?.pixelBuffer else { return nil }
      return fitted(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]), to: image)
    } catch {
      return nil
    }
  }

  private static func fitted(_ mask: CIImage, to image: CGImage) -> CIImage {
    let extent = mask.extent
    let scaled = opaque(mask.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)))
      .transformed(by: CGAffineTransform(scaleX: CGFloat(image.width) / extent.width, y: CGFloat(image.height) / extent.height))
    return scaled.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  }
}
