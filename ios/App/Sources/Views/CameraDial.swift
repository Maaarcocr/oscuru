import SwiftUI

/// A mark on a dial: where it is, and what is written by it (a few words, or a symbol).
struct DialMark {
    let position: Double
    var label: String?
    var symbol: String?

    var isLabelled: Bool { label != nil || symbol != nil }
}

/// A value as a dial, as in the Camera app: an arc of marks that turns under the finger, with the
/// value now at its top. One unit of position is the same turn anywhere on it, so a dial of zoom
/// or of exposure is laid out in doublings: a stop is always the same distance.
struct CameraDial: View {
    /// Where the dial is turned to.
    let position: Double
    let marks: [DialMark]
    /// The value now, written over the top of the dial.
    let text: String
    /// What the dial sets, for VoiceOver.
    let name: String
    /// How the dial is geared: how far it turns, and how far a finger moves, for one unit.
    var gearing = Gearing.fine
    /// For VoiceOver, which turns it a step at a time: +1 or −1.
    let step: (Int) -> Void

    struct Gearing {
        let degreesPerUnit: Double
        /// How far a finger moves for a unit: about the same turn on the dial.
        let pointsPerUnit: Double

        /// For a value set finely over a short range: zoom (a unit is a doubling) and focus.
        static let fine = Gearing(degreesPerUnit: 34, pointsPerUnit: 180)
        /// For a value that goes through many stops: time, ISO, aperture, frames (a unit is a stop).
        /// Two stops either side are in view, and a swipe across the screen goes through six.
        static let stops = Gearing(degreesPerUnit: 17, pointsPerUnit: 64)

        /// How far a drag turns the dial, in units: left or up is further along.
        func turn(_ translation: CGSize) -> Double {
            -(translation.width + translation.height) / pointsPerUnit
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let radius = width * 0.85
            let centre = CGPoint(x: width / 2, y: 46 + radius)
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                    .frame(width: radius * 2 + 56, height: radius * 2 + 56)
                    .position(centre)
                Canvas { context, _ in
                    for mark in marks {
                        let angle = (mark.position - position) * gearing.degreesPerUnit * .pi / 180
                        guard abs(angle) < 1.1 else { continue }
                        func point(_ distance: Double) -> CGPoint {
                            CGPoint(x: centre.x + distance * sin(angle), y: centre.y - distance * cos(angle))
                        }
                        var line = Path()
                        line.move(to: point(radius))
                        line.addLine(to: point(radius - (mark.isLabelled ? 14 : 7)))
                        context.stroke(line, with: .color(.white.opacity(mark.isLabelled ? 0.95 : 0.45)), lineWidth: mark.isLabelled ? 2 : 1)
                        if let label = mark.label {
                            let text = Text(verbatim: label).font(.caption.weight(.semibold)).foregroundStyle(Color.white)
                            context.draw(context.resolve(text), at: point(radius - 30), anchor: .center)
                        } else if let symbol = mark.symbol {
                            let image = Text(Image(systemName: symbol)).font(.caption.weight(.semibold)).foregroundStyle(Color.white)
                            context.draw(context.resolve(image), at: point(radius - 30), anchor: .center)
                        }
                    }
                }
                // The value now, over the top of the dial.
                VStack(spacing: 3) {
                    Text(verbatim: text)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 14)
                }
                .position(x: width / 2, y: 27)
            }
        }
        .frame(height: 150)
        .clipped()
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(Text(verbatim: text))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("camera.dial")
    }
}
