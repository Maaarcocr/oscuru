<h1 align="center">Oscuru</h1>

<p align="center">
  A RAW photo editor for iPhone where you say what you want and an AI edits the photo, like a retoucher would.<br>
  English · Italiano
</p>

---

Oscuru ("dark" in Sicilian) has no sliders. You open a RAW photo and type what you want: "make it cinematic", "recover the sky", "warmer, but keep the skin natural". An assistant develops the photo for you with the controls of a professional RAW developer — exposure, white balance, tone curves, HSL, colour grading, detail, crop — and keeps going until it looks right.

The assistant never generates or alters image content. It writes small JavaScript programs against a documented photo API; the phone runs them and renders the result with its own RAW engine. After every change the assistant sees the photo before and after, and decides what to do next.

## What it does

- **One screen.** The photo, and a place to say what you want. Touch and hold to see the original; pinch to zoom.
- **An assistant that looks.** It sees the photo before and after each step, can zoom into any part of it, and measures what it needs (histogram, clipping, colour casts). It works as long as the photo needs, and you can stop it at any time.
- **Undo everything.** Every step is an undo step; one tap reverts everything the assistant did for a request.
- **Saved filters.** Save a look and apply it to any photo, yourself or by asking the assistant.
- **Real RAW development.** Apple ProRAW, DNG and the camera RAW formats iOS reads, plus JPEG and HEIC, developed on the phone with Core Image. Originals are never changed. Export at full resolution to JPEG or HEIC.
- **Your model, your account.** The assistant runs on any OpenRouter model that reads images and calls tools, with your own sign-in. The app records what it costs and sets no limits of its own.

## How it's built

A native iPhone app: Swift, SwiftUI, Core Image and JavaScriptCore. No server, no web views, no React Native.

```
ios/App                         SwiftUI app: library, the photo screen, filters, settings
ios/Packages/OscuruKit
  OscuruCore                    editing state, colour pipeline, filters, history, the agent loop,
                                the OpenRouter client, the photo API and prompt (pure Swift, also builds on Linux)
  OscuruEngine                  RAW decoding and rendering with Core Image
  OscuruScripting               the JavaScriptCore environment scripts run in
docs/photo-api.d.ts             the scripting API the assistant is given
```

Details: **[docs/architecture.md](docs/architecture.md)**. Building and publishing: **[docs/expo.md](docs/expo.md)**.

## Working on it

```sh
swift test --package-path ios/Packages/OscuruKit     # core on any OS; engine and scripting on macOS
python3 scripts/check-strings.py                      # English and Italian complete
(cd ios && xcodegen generate) && open ios/Oscuru.xcodeproj
./scripts/test-ios.sh                                 # UI tests on a simulator, in English and Italian
```

CI runs all of that on every push, including the UI test on an iPhone simulator, and keeps its screenshots.

## Privacy

No account, no server, no analytics. Photos and edits stay on the phone. When you use the assistant, pictures of the photo, its settings and its capture details go to OpenRouter and the model you chose, under your own OpenRouter account. Your key is kept in the keychain.

## Licence

AGPL-3.0. See [LICENSE](LICENSE).
