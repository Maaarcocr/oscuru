import CoreMotion
import OscuruCore
import SwiftUI

/// How the frame's tones are spread, darkest on the left. Its right edge lights up when part of
/// the frame is blown.
struct Histogram: View {
    let statistics: FrameStatistics?

    var body: some View {
        Canvas { context, size in
            guard let statistics, let peak = statistics.histogram.max(), peak > 0 else { return }
            let bins = statistics.histogram
            var shape = Path()
            shape.move(to: CGPoint(x: 0, y: size.height))
            for (index, share) in bins.enumerated() {
                // By its square root: a night sky is most of the frame, and the little that is bright
                // is what has to be seen beside it.
                let top = size.height * (1 - sqrt(Double(share / peak)))
                shape.addLine(to: CGPoint(x: size.width * Double(index) / Double(bins.count), y: top))
                shape.addLine(to: CGPoint(x: size.width * Double(index + 1) / Double(bins.count), y: top))
            }
            shape.addLine(to: CGPoint(x: size.width, y: size.height))
            shape.closeSubpath()
            context.fill(shape, with: .color(.white.opacity(0.85)))
            if statistics.blownShare > 0 {
                context.fill(Path(CGRect(x: size.width - 2.5, y: 0, width: 2.5, height: size.height)), with: .color(.red))
            }
        }
        .frame(width: 52, height: 26)
        .background(Color.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(L10n.cameraHistogram)
        .accessibilityValue(Text(verbatim: (statistics?.blownShare ?? 0) > 0 ? L10n.cameraHighlightsBlown : ""))
        .accessibilityIdentifier("camera.histogram")
    }
}

/// Stripes over the parts of the viewfinder where a colour is blown: nothing more can be recorded
/// there, whatever is done to the photo afterwards.
struct BlownMarks: View {
    let statistics: FrameStatistics
    /// How far the measured frame is turned to stand upright, in degrees clockwise.
    let rotation: Double

    var body: some View {
        if statistics.blownShare > 0, let map {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.6)))
                var stripes = Path()
                var x = -size.height
                while x < size.width {
                    stripes.move(to: CGPoint(x: x, y: size.height))
                    stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 7
                }
                context.stroke(stripes, with: .color(.white), lineWidth: 2.5)
            }
            .mask {
                Image(decorative: map, scale: 1, orientation: orientation)
                    .resizable()
                    .interpolation(.low)
                    .luminanceToAlpha()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var orientation: Image.Orientation {
        switch Int(rotation.rounded()) {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    /// The map of the frame as a picture: white where it is blown.
    private var map: CGImage? {
        guard statistics.width > 0, statistics.height > 0, let provider = CGDataProvider(data: Data(statistics.blown) as CFData) else { return nil }
        return CGImage(
            width: statistics.width, height: statistics.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: statistics.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Lines at the thirds of the viewfinder, for composing.
struct ThirdsGrid: View {
    var body: some View {
        Canvas { context, size in
            var lines = Path()
            for third in [1.0 / 3, 2.0 / 3] {
                lines.move(to: CGPoint(x: size.width * third, y: 0))
                lines.addLine(to: CGPoint(x: size.width * third, y: size.height))
                lines.move(to: CGPoint(x: 0, y: size.height * third))
                lines.addLine(to: CGPoint(x: size.width, y: size.height * third))
            }
            context.stroke(lines, with: .color(.black.opacity(0.25)), lineWidth: 1.5)
            context.stroke(lines, with: .color(.white.opacity(0.55)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Which way the horizon runs across the screen, from the phone's motion sensor.
@MainActor
@Observable
final class Level {
    /// The horizon's angle on the screen, clockwise, in radians: 0 when the phone is held upright and
    /// level, about ±π/2 when it is level on its side. Nil while the phone lies flat, or has no sensor.
    private(set) var angle: Double?
    @ObservationIgnored private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            MainActor.assumeIsolated {
                // Lying flat, there is no horizon to show.
                self?.angle = abs(gravity.z) > 0.85 ? nil : -atan2(gravity.x, -gravity.y)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        angle = nil
    }

    /// How far the horizon is from the nearest level way of holding the phone (upright or on its side).
    nonisolated static func tilt(_ angle: Double) -> Double {
        angle - (angle / (.pi / 2)).rounded() * (.pi / 2)
    }

    /// Within a degree of level.
    nonisolated static func isLevel(_ angle: Double) -> Bool { abs(tilt(angle)) < .pi / 180 }

    /// Close enough to level for the mark to help; beyond that it is a different way of holding the phone.
    nonisolated static func isNearLevel(_ angle: Double) -> Bool { abs(tilt(angle)) < .pi / 9 }
}

/// The level, as in the Camera app: short marks where level is and a line that follows the horizon;
/// within a degree they meet in one yellow line.
struct LevelMark: View {
    let angle: Double

    var body: some View {
        let level = Level.isLevel(angle)
        let square = angle - Level.tilt(angle)
        ZStack {
            HStack(spacing: 74) {
                Capsule().frame(width: 16, height: 1.5)
                Capsule().frame(width: 16, height: 1.5)
            }
            .rotationEffect(.radians(square))
            Capsule()
                .frame(width: level ? 106 : 60, height: 1.5)
                .rotationEffect(.radians(level ? square : angle))
        }
        .foregroundStyle(level ? Color.accentColor : Color.white)
        .shadow(color: .black.opacity(0.4), radius: 1)
        .animation(.snappy(duration: 0.15), value: level)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
