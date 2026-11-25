import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import OscuruCore

extension Effects {
  /// A collage's canvas, `width` by `height` pixels, with its extent at the origin: the background,
  /// then each cell's piece scaled (with a Lanczos filter) to cover the cell around its focus, in
  /// order. Pieces are the collage's developed photos; nothing here makes pixels of its own.
  static func collage(_ layout: CollageLayout, pieces: [CIImage], width: Int, height: Int) -> CIImage {
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    let rgb = layout.backgroundColor
    let background =
      CGColorSpace(name: CGColorSpace.sRGB).flatMap { CIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1, colorSpace: $0) }
      ?? CIColor(red: 1, green: 1, blue: 1)
    var image = CIImage(color: background).cropped(to: canvas)
    for frame in layout.frames(width: Double(width), height: Double(height)) where pieces.indices.contains(frame.cell.piece) {
      let piece = pieces[frame.cell.piece]
      let extent = piece.extent
      guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { continue }
      let window = frame.cell.window(pieceWidth: extent.width, pieceHeight: extent.height, cellWidth: frame.width, cellHeight: frame.height)
      let scale = frame.width / window.width
      // Edge pixels repeated a little way out, so the filter does not fade the piece's own edges.
      let margin = (4 / min(1, scale)).rounded(.up)
      let resize = CIFilter.lanczosScaleTransform()
      resize.inputImage = piece.clampedToExtent().cropped(to: extent.insetBy(dx: -margin, dy: -margin))
      resize.scale = Float(scale)
      resize.aspectRatio = 1
      guard let scaled = resize.outputImage else { continue }
      // The window's lower-left corner in the scaled piece, and the cell on the canvas; Core Image measures y from the bottom.
      let corner = CGPoint(x: (extent.minX + window.x) * scale, y: (extent.minY + extent.height - window.y - window.height) * scale)
      let cell = CGRect(x: frame.x, y: Double(height) - frame.y - frame.height, width: frame.width, height: frame.height)
      let placed = scaled.transformed(by: CGAffineTransform(translationX: cell.minX - corner.x, y: cell.minY - corner.y)).cropped(to: cell)
      image = placed.composited(over: image)
    }
    return image.cropped(to: canvas)
  }
}
