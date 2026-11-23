import Foundation

/// The point operations of the pipeline, evaluated in display-referred (gamma-encoded) Display P3:
///
///     tone    per channel: dehaze veil → blacks / whites → contrast → highlights (+) / shadows (−)
///             → master curve → channel curve
///     colour  HSL ranges → vibrance → saturation → colour grading
///
/// The renderer does not run this per pixel. It applies `toneTables` as a 1D table per channel and
/// `colorCube` as a 3D table, both in Display P3, so what the tests check here is exactly what
/// reaches the photo. Exposure, white balance, the recovering directions of highlights and
/// shadows, and everything that needs neighbouring pixels happen in the engine.
public enum ColorPipeline {
    /// Fine enough that a lookup needs no interpolation between entries.
    public static let toneTableSize = 1024
    public static let cubeSize = 33

    /// Centres of the eight HSL ranges, in degrees around the colour wheel.
    public static let rangeHues: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]

    /// Display P3 luma.
    public static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.229 * r + 0.6917 * g + 0.0793 * b
    }

    static func clamp01(_ value: Double) -> Double { value < 0 ? 0 : value > 1 ? 1 : value }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = clamp01((value - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    /// A smooth curve through the control points that never overshoots between them
    /// (monotone cubic, Fritsch–Carlson). Flat before the first point and after the last.
    public static func curve(_ points: [[Double]]) -> @Sendable (Double) -> Double {
        let n = points.count
        let xs = points.map { $0[0] }
        let ys = points.map { $0[1] }
        var slopes: [Double] = []
        for i in 0..<(n - 1) { slopes.append((ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])) }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) { tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2 }
        }
        for i in 0..<(n - 1) {
            if slopes[i] == 0 {
                tangents[i] = 0
                tangents[i + 1] = 0
                continue
            }
            let a = tangents[i] / slopes[i]
            let b = tangents[i + 1] / slopes[i]
            let length = a * a + b * b
            if length > 9 {
                let scale = 3 / length.squareRoot()
                tangents[i] = scale * a * slopes[i]
                tangents[i + 1] = scale * b * slopes[i]
            }
        }
        let finalTangents = tangents
        return { x in
            if x <= xs[0] { return ys[0] }
            if x >= xs[n - 1] { return ys[n - 1] }
            var i = 0
            while x > xs[i + 1] { i += 1 }
            let h = xs[i + 1] - xs[i]
            let t = (x - xs[i]) / h
            let t2 = t * t
            let t3 = t2 * t
            let value =
                (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * finalTangents[i] + (-2 * t3 + 3 * t2) * ys[i + 1]
                + (t3 - t2) * h * finalTangents[i + 1]
            return clamp01(value)
        }
    }

    /// The basic tone controls as one function of a channel value, before any curves.
    public static func basicTone(_ state: EditingState) -> @Sendable (Double) -> Double {
        let veil = state.value("dehaze") / 100
        let black = state.value("blacks") / 100 * 0.2
        let white = state.value("whites") / 100 * 0.2
        let contrast = state.value("contrast") / 100
        // Only the directions that do not recover detail are point operations; the others are local.
        let brighten = state.value("highlights") > 0 ? state.value("highlights") / 100 * 0.12 : 0
        let deepen = state.value("shadows") < 0 ? state.value("shadows") / 100 * 0.12 : 0
        return { input in
            var x = input
            if veil > 0 {
                let floor = 0.12 * veil
                x = (x - floor) / (1 - floor)
            } else if veil < 0 {
                x = x * (1 + 0.3 * veil) - 0.3 * veil * 0.85
            }
            if black != 0 { x += black * pow(1 - clamp01(x), 3) }
            if white != 0 { x += white * pow(clamp01(x), 3) }
            x = clamp01(x)
            if contrast > 0 {
                let t = 2 * x - 1
                let shaped = 1 - pow(1 - abs(t), 1 + contrast)
                x = 0.5 + 0.5 * (t < 0 ? -shaped : shaped)
            } else if contrast < 0 {
                x = 0.5 + (x - 0.5) * (1 + 0.5 * contrast)
            }
            if brighten != 0 { x += brighten * 6.75 * x * x * (1 - x) }
            if deepen != 0 { x += deepen * 6.75 * x * (1 - x) * (1 - x) }
            return clamp01(x)
        }
    }

    static func toneIsIdentity(_ state: EditingState) -> Bool {
        state.value("blacks") == 0 && state.value("whites") == 0 && state.value("contrast") == 0 && state.value("highlights") <= 0
            && state.value("shadows") >= 0 && state.value("dehaze") == 0 && Specs.curveChannels.allSatisfy(state.isIdentityCurve)
    }

    /// The whole tone stage as three 1D tables (red, green, blue interleaved), or nil when it
    /// changes nothing. Entry i is the output for input i / (size − 1).
    public static func toneTables(_ state: EditingState, size: Int = toneTableSize) -> [Float]? {
        if toneIsIdentity(state) { return nil }
        let basic = basicTone(state)
        let master = curve(state.curves["rgb"]!)
        let channels = [curve(state.curves["red"]!), curve(state.curves["green"]!), curve(state.curves["blue"]!)]
        var table = [Float](repeating: 0, count: size * 3)
        for i in 0..<size {
            let shared = master(basic(Double(i) / Double(size - 1)))
            for channel in 0..<3 { table[i * 3 + channel] = Float(channels[channel](shared)) }
        }
        return table
    }

    // MARK: Base curve

    /// Where Oscuru's base curve stops being the identity, in linear light (1 is the decoder's white).
    public static let baseCurveKnee = 0.75
    /// The brightest linear value the base curve table covers; anything brighter is white.
    public static let baseCurveMaximum = 8.0
    public static let baseCurveTableSize = 4096

    /// Oscuru's base curve for RAW files: from the scene-linear light the RAW decoder measures to
    /// display light, per channel. Up to `baseCurveKnee` it is the identity: the light exactly as
    /// the sensor measured it, with no lift, toe or contrast. Above, it rolls off smoothly towards
    /// white, starting with the same slope so there is no visible joint, so bright highlights
    /// compress instead of clipping. That is all it does; every other choice about the look is
    /// made in the conversation.
    public static func baseCurve(_ x: Double) -> Double {
        if x <= baseCurveKnee { return Swift.max(0, x) }
        let room = 1 - baseCurveKnee
        return baseCurveKnee + room * (1 - exp(-(x - baseCurveKnee) / room))
    }

    /// The sRGB (and Display P3) transfer function, extended past 1 for values brighter than white.
    public static func encode(_ linear: Double) -> Double {
        linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    public static func decode(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    /// The upper end of the base curve table's input, in encoded (extended Display P3) values.
    public static var baseCurveDomain: Double { encode(baseCurveMaximum) }

    /// The base curve as a table for Core Image's colour curves, applied in extended Display P3:
    /// `size` entries evenly spaced over encoded input 0...`baseCurveDomain`, the same value for
    /// red, green and blue, encoded output. Encoded steps are fine in the shadows, where linear
    /// steps would band.
    public static func baseCurveTable(size: Int = baseCurveTableSize) -> [Float] {
        let domain = baseCurveDomain
        var table = [Float](repeating: 0, count: size * 3)
        for i in 0..<size {
            let input = decode(Double(i) / Double(size - 1) * domain)
            let value = Float(encode(baseCurve(input)))
            for channel in 0..<3 { table[i * 3 + channel] = value }
        }
        return table
    }

    static func hue(_ r: Double, _ g: Double, _ b: Double, max: Double, chroma: Double) -> Double {
        var hue: Double
        if max == r {
            hue = ((g - b) / chroma).truncatingRemainder(dividingBy: 6)
        } else if max == g {
            hue = (b - r) / chroma + 2
        } else {
            hue = (r - g) / chroma + 4
        }
        hue *= 60
        return hue < 0 ? hue + 360 : hue
    }

    /// A unit-strength colour offset for a hue that adds no luma: the direction a tint pushes towards.
    static func tintDirection(_ hue: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let rgb: (Double, Double, Double)
        switch Int(h) {
        case 0: rgb = (1, x, 0)
        case 1: rgb = (x, 1, 0)
        case 2: rgb = (0, 1, x)
        case 3: rgb = (0, x, 1)
        case 4: rgb = (x, 0, 1)
        default: rgb = (1, 0, x)
        }
        let y = luma(rgb.0, rgb.1, rgb.2)
        return (rgb.0 - y, rgb.1 - y, rgb.2 - y)
    }

    /// Pulls a colour back inside 0–1 by reducing its colourfulness, keeping its luma.
    static func fitGamut(_ r: inout Double, _ g: inout Double, _ b: inout Double) {
        let y = clamp01(luma(r, g, b))
        var scale = 1.0
        for value in [r, g, b] {
            let delta = value - y
            if value > 1, delta > 0 { scale = Swift.min(scale, (1 - y) / delta) } else if value < 0, delta < 0 { scale = Swift.min(scale, y / -delta) }
        }
        r = clamp01(y + (r - y) * scale)
        g = clamp01(y + (g - y) * scale)
        b = clamp01(y + (b - y) * scale)
    }

    static func gradeIsOff(_ grade: [String: Double]) -> Bool { (grade["saturation"] ?? 0) == 0 && (grade["luminance"] ?? 0) == 0 }

    static func colorIsIdentity(_ state: EditingState) -> Bool {
        state.value("vibrance") == 0 && state.value("saturation") == 0 && state.value("dehaze") == 0
            && state.hsl.values.allSatisfy { $0.values.allSatisfy { $0 == 0 } }
            && gradeIsOff(state.grading.shadows) && gradeIsOff(state.grading.midtones) && gradeIsOff(state.grading.highlights)
    }

    /// The colour stage for one state, ready to apply to any number of colours.
    struct ColorStage {
        let hslHue: [Double]
        let hslSaturation: [Double]
        let hslLuminance: [Double]
        let hslActive: Bool
        let vibrance: Double
        let saturation: Double
        let gradingActive: Bool
        let tints: [(Double, Double, Double)]
        let balancePower: Double
        let rangePower: Double

        init(_ state: EditingState) {
            hslHue = Specs.colorRanges.map { (state.hsl[$0]?["hue"] ?? 0) / 100 }
            hslSaturation = Specs.colorRanges.map { (state.hsl[$0]?["saturation"] ?? 0) / 100 }
            hslLuminance = Specs.colorRanges.map { (state.hsl[$0]?["luminance"] ?? 0) / 100 }
            hslActive = !state.hsl.values.allSatisfy { $0.values.allSatisfy { $0 == 0 } }
            vibrance = state.value("vibrance") / 100
            // Dehaze also restores (or washes out) some colour.
            saturation = (1 + state.value("saturation") / 100) * (1 + 0.2 * (state.value("dehaze") / 100))
            let grading = state.grading
            gradingActive = !gradeIsOff(grading.shadows) || !gradeIsOff(grading.midtones) || !gradeIsOff(grading.highlights)
            tints = [grading.shadows, grading.midtones, grading.highlights].map { grade in
                let direction = tintDirection(grade["hue"] ?? 0)
                let strength = (grade["saturation"] ?? 0) * 0.5
                let lift = (grade["luminance"] ?? 0) * 0.3
                return (direction.0 * strength + lift, direction.1 * strength + lift, direction.2 * strength + lift)
            }
            balancePower = pow(2, -grading.balance)
            rangePower = 2 + 3 * (1 - grading.blending)
        }

        func apply(_ r: inout Double, _ g: inout Double, _ b: inout Double) {
            var maxValue = Swift.max(r, g, b)
            var chroma = maxValue - Swift.min(r, g, b)

            if hslActive, chroma > 1e-5 {
                let hue = ColorPipeline.hue(r, g, b, max: maxValue, chroma: chroma)
                // Near-greys and near-blacks have no reliable hue: fade the adjustment out there.
                let mask = smoothstep(0.04, 0.25, chroma / maxValue) * smoothstep(0.02, 0.12, maxValue)
                var index = 7
                for i in 0..<7 where hue < rangeHues[i + 1] {
                    index = i
                    break
                }
                let next = (index + 1) % 8
                let span = (index == 7 ? 360 : rangeHues[next]) - rangeHues[index]
                let t = (hue - rangeHues[index]) / span
                let w0 = (1 - t) * mask
                let w1 = t * mask
                let hueShift = (w0 * hslHue[index] + w1 * hslHue[next]) * 30
                let saturationShift = w0 * hslSaturation[index] + w1 * hslSaturation[next]
                let luminanceShift = w0 * hslLuminance[index] + w1 * hslLuminance[next]
                let y = luma(r, g, b)
                if hueShift != 0 {
                    // Turn the colour around the grey axis, then restore its luma.
                    let angle = hueShift * .pi / 180
                    let cosine = cos(angle)
                    let k = (1 - cosine) / 3
                    let s = sin(angle) / 3.0.squareRoot()
                    let nr = r * (cosine + k) + g * (k - s) + b * (k + s)
                    let ng = r * (k + s) + g * (cosine + k) + b * (k - s)
                    let nb = r * (k - s) + g * (k + s) + b * (cosine + k)
                    let fix = y - luma(nr, ng, nb)
                    r = nr + fix
                    g = ng + fix
                    b = nb + fix
                }
                if saturationShift != 0 {
                    let factor = 1 + saturationShift
                    r = y + (r - y) * factor
                    g = y + (g - y) * factor
                    b = y + (b - y) * factor
                }
                if luminanceShift != 0 {
                    let factor = 1 + 0.6 * luminanceShift
                    r *= factor
                    g *= factor
                    b *= factor
                }
                fitGamut(&r, &g, &b)
                maxValue = Swift.max(r, g, b)
                chroma = maxValue - Swift.min(r, g, b)
            }

            var factor = saturation
            if vibrance != 0, chroma > 1e-5 {
                let colourfulness = chroma / maxValue
                if vibrance > 0 {
                    let hue = ColorPipeline.hue(r, g, b, max: maxValue, chroma: chroma)
                    let skin = Swift.max(0, 1 - abs(hue - 25) / 25)
                    factor *= 1 + vibrance * pow(1 - colourfulness, 1.5) * (1 - 0.5 * skin)
                } else {
                    factor *= 1 + vibrance * (1 - 0.5 * colourfulness)
                }
            }
            if factor != 1 {
                let y = luma(r, g, b)
                r = y + (r - y) * factor
                g = y + (g - y) * factor
                b = y + (b - y) * factor
                fitGamut(&r, &g, &b)
            }

            if gradingActive {
                let y = pow(clamp01(luma(r, g, b)), balancePower)
                let shadows = pow(1 - y, rangePower)
                let highlights = pow(y, rangePower)
                let midtones = 1 - shadows - highlights
                r += shadows * tints[0].0 + midtones * tints[1].0 + highlights * tints[2].0
                g += shadows * tints[0].1 + midtones * tints[1].1 + highlights * tints[2].1
                b += shadows * tints[0].2 + midtones * tints[1].2 + highlights * tints[2].2
            }

            r = clamp01(r)
            g = clamp01(g)
            b = clamp01(b)
        }
    }

    /// The colour stage as a 3D table of RGBA floats with red varying fastest (the layout Core
    /// Image expects), or nil when it changes nothing.
    public static func colorCube(_ state: EditingState, size: Int = cubeSize) -> [Float]? {
        if colorIsIdentity(state) { return nil }
        let stage = ColorStage(state)
        var cube = [Float](repeating: 1, count: size * size * size * 4)
        let step = 1 / Double(size - 1)
        var offset = 0
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    var r = Double(red) * step
                    var g = Double(green) * step
                    var b = Double(blue) * step
                    stage.apply(&r, &g, &b)
                    cube[offset] = Float(r)
                    cube[offset + 1] = Float(g)
                    cube[offset + 2] = Float(b)
                    offset += 4
                }
            }
        }
        return cube
    }

    /// Runs one Display P3 colour through the tone and colour stages exactly (no cube lookup).
    public static func apply(_ state: EditingState, to input: (Double, Double, Double)) -> (Double, Double, Double) {
        var r = clamp01(input.0)
        var g = clamp01(input.1)
        var b = clamp01(input.2)
        if !toneIsIdentity(state) {
            let basic = basicTone(state)
            let master = curve(state.curves["rgb"]!)
            r = curve(state.curves["red"]!)(master(basic(r)))
            g = curve(state.curves["green"]!)(master(basic(g)))
            b = curve(state.curves["blue"]!)(master(basic(b)))
        }
        if !colorIsIdentity(state) { ColorStage(state).apply(&r, &g, &b) }
        return (r, g, b)
    }
}
