import CoreGraphics
import Foundation
import ImageIO
import OscuruCore
import UniformTypeIdentifiers

/// What UI tests run against (`-ui-testing`): a library in a temporary folder with one sample
/// photo, an account that is already connected, and a model that plays back a short conversation.
/// Nothing touches the network or the keychain.
enum UITesting {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-ui-testing") }

    static let root: URL = FileManager.default.temporaryDirectory.appending(path: "oscuru-ui-testing-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Answers the two OpenRouter calls the app makes outside the agent loop.
    static let transport: HTTPTransport = { request in
        let body: JSONValue
        if request.url.hasSuffix("/key") {
            body = ["data": ["label": "sk-or-v1-test…1a2b", "usage": 1.42, "limit": nil, "limit_remaining": nil]]
        } else if request.url.contains("/models") {
            body = [
                "data": [
                    [
                        "id": "anthropic/claude-sonnet-5.5", "name": "Anthropic: Claude Sonnet 5.5", "architecture": ["input_modalities": ["text", "image"]],
                        "supported_parameters": ["tools"], "pricing": ["prompt": "0.000002", "completion": "0.00001"],
                    ],
                    [
                        "id": "google/gemini-4-carbon", "name": "Google: Gemini 4 Carbon", "architecture": ["input_modalities": ["text", "image"]],
                        "supported_parameters": ["tools"], "pricing": ["prompt": "0.000002", "completion": "0.00001"],
                    ],
                ]
            ]
        } else {
            return HTTPResponse(status: 404, body: Data())
        }
        return HTTPResponse(status: 200, body: Data(body.text().utf8))
    }

    /// A landscape drawn in code: sky, sun, hills, water. Enough tone and colour to see an edit.
    static func samplePhoto() -> URL? {
        let width = 1200
        let height = 800
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
        // Core Graphics draws from the bottom-left corner.
        let sky = CGGradient(colorsSpace: space, colors: [colour(1, 0.97, 0.9), colour(0.95, 0.88, 0.78), colour(0.43, 0.58, 0.79)] as CFArray, locations: [0, 0.3, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 330), end: CGPoint(x: 0, y: 800), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let sun = CGGradient(colorsSpace: space, colors: [colour(1, 1, 0.98), colour(1, 0.94, 0.78, 0.9), colour(1, 0.86, 0.63, 0)] as CFArray, locations: [0, 0.15, 1])!
        context.drawRadialGradient(sun, startCenter: CGPoint(x: 830, y: 450), startRadius: 6, endCenter: CGPoint(x: 830, y: 450), endRadius: 280, options: [])
        func hill(_ fill: CGColor, base: CGFloat, height: CGFloat, frequency: CGFloat, phase: CGFloat) {
            context.setFillColor(fill)
            context.move(to: CGPoint(x: 0, y: 0))
            for x in stride(from: CGFloat(0), through: 1200, by: 8) {
                context.addLine(to: CGPoint(x: x, y: base + sin(x * frequency + phase) * height + sin(x * frequency * 2.7 + phase) * height * 0.3))
            }
            context.addLine(to: CGPoint(x: 1200, y: 0))
            context.fillPath()
        }
        hill(colour(0.49, 0.56, 0.64), base: 375, height: 40, frequency: 0.006, phase: 1)
        hill(colour(0.34, 0.44, 0.37), base: 320, height: 46, frequency: 0.009, phase: 2)
        hill(colour(0.18, 0.29, 0.21), base: 250, height: 34, frequency: 0.0135, phase: 4)
        let water = CGGradient(colorsSpace: space, colors: [colour(0.15, 0.25, 0.35), colour(0.54, 0.66, 0.77)] as CFArray, locations: [0, 1])!
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: 1200, height: 180))
        context.drawLinearGradient(water, start: .zero, end: CGPoint(x: 0, y: 180), options: [])
        context.restoreGState()
        hill(colour(0.09, 0.15, 0.11), base: 70, height: 24, frequency: 0.018, phase: 0.5)
        guard let image = context.makeImage() else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "Lake at dusk.jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}

/// A model that edits like a colourist would, from a script: one look at the photo, two scripts
/// (the second refines the first), then a closing note. It reads the revision it was last told,
/// as a real model does.
struct ScriptedModel: ModelClient {
    func chat(_ request: ChatRequest) async throws -> ChatResponse {
        try await Task.sleep(for: .milliseconds(600))
        var session = ""
        var revision = 1
        var turnStart = 0
        var instruction = ""
        for (index, message) in request.messages.enumerated() {
            if message["role"] == "tool", let reported = JSONValue(text: message["content"]?.stringValue ?? "")?["revision"]?.doubleValue {
                revision = Int(reported)
            }
            // The instruction and context are the first text part; picture labels follow it.
            let text = message["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            guard message["role"] == "user", let marker = text.range(of: "[Photo context]\n") else { continue }
            var json = String(text[marker.upperBound...])
            if let extra = json.range(of: "\n\n[") { json = String(json[..<extra.lowerBound]) }
            let context = JSONValue(text: json)
            session = context?["sessionId"]?.stringValue ?? session
            revision = Int(context?["revision"]?.doubleValue ?? Double(revision))
            turnStart = index
            instruction = String(text[..<marker.lowerBound])
        }
        let callsSoFar = request.messages[turnStart...].filter { $0["role"] == "tool" }.count

        func call(_ code: String, saying: String) -> ChatResponse {
            let arguments: JSONValue = ["sessionId": .string(session), "baseRevision": .number(Double(revision)), "code": .string(code)]
            let message: JSONValue = [
                "role": "assistant", "content": .string(saying),
                "tool_calls": [["id": .string("call-\(revision)-\(callsSoFar)"), "type": "function", "function": ["name": .string(Prompt.toolName), "arguments": .string(arguments.text())]]],
            ]
            return ChatResponse(id: "scripted", model: request.model, message: message, usage: Usage(promptTokens: 6200, completionTokens: 310, cost: 0.0154))
        }
        func note(_ text: String) -> ChatResponse {
            ChatResponse(id: "scripted", model: request.model, message: ["role": "assistant", "content": .string(text)], usage: Usage(promptTokens: 8100, completionTokens: 90, cost: 0.0171))
        }

        if instruction.lowercased().contains("filter") {
            if callsSoFar == 0 { return call("photo.filters.save(\"Dusk\");\nphoto.filters.list();", saying: "") }
            return note("Saved this look as the filter “Dusk”. You can apply it to any photo from Filters.")
        }
        switch callsSoFar {
        case 0:
            return call(
                """
                const image = photo.current;
                const { global } = image.getState();
                const before = image.getStatistics();
                image.adjust({
                  exposureEV: before.highlightClipping > 0.02 ? global.exposureEV - 0.25 : global.exposureEV,
                  highlights: -45,
                  shadows: 28,
                  contrast: 8,
                  vibrance: -6,
                });
                image.curves.set("rgb", [[0, 0.03], [0.25, 0.21], [0.5, 0.5], [0.75, 0.8], [1, 0.98]]);
                image.grading.set("shadows", { hue: 215, saturation: 0.14 });
                image.grading.set("highlights", { hue: 40, saturation: 0.1 });
                const after = image.getStatistics();
                ({ clippingBefore: before.highlightClipping, clippingAfter: after.highlightClipping });
                """, saying: "Starting with a restrained cinematic grade.")
        case 1:
            return call(
                """
                photo.current.hsl.adjust("blue", { saturation: -10, luminance: -6 });
                photo.current.adjust({ vignette: -18 });
                photo.show("current", { region: { x: 0.5, y: 0.2, width: 0.4, height: 0.4 } });
                """, saying: "The sky is back. Calming the blues a little and checking the sun up close.")
        default:
            return note(
                "I pulled the highlights down to bring the sky back, opened the shadows, and added a gentle S-curve. Shadows lean cool and highlights warm for the cinematic feel, with the blues held back so it stays natural."
            )
        }
    }
}
