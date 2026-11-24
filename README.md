<h1 align="center">Oscuru</h1>

<p align="center">
  A RAW photo editor for iPhone where you say what you want and an AI edits the photo, like a retoucher would.<br>
  English · Italiano
</p>

---

Oscuru ("dark" in Sicilian) has no sliders. You open a RAW photo and type what you want: "make it cinematic", "recover the sky", "warmer, but keep the skin natural". An assistant develops the photo for you with the controls of a professional RAW developer — exposure, white balance, tone curves, HSL, colour grading, detail, crop — and keeps going until it looks right.

The assistant never uses AI image generation and never invents content. It writes small JavaScript programs against a documented photo API; the phone runs them and renders the result with its own RAW engine. After every change the assistant sees the photo before and after, and decides what to do next.

## What it does

- **A camera that doesn't process.** Shoot single-frame Bayer RAW: no Smart HDR, Deep Fusion, night mode, noise reduction or sharpening at capture, just what the sensor saw, kept as a DNG. The shot opens as a new conversation.
- **A conversation.** Each photo is a thread: the original, what you asked for, and the version that came back. Open any version to zoom in or compare it with the one before. Nothing is lost: the thread survives a dropped connection or the app closing, and the assistant picks up where it stopped. You can keep talking while it works.
- **An assistant that looks.** It sees the photo before and after each step, can zoom into any part of it, and measures what it needs (histogram, clipping, colour casts). It works as long as the photo needs, and you can stop it at any time.
- **Every version kept.** Any earlier version in the thread can be opened, compared and brought back; the thread is saved with the photo.
- **Edits to part of the photo.** The assistant selects an object by pointing at it (the phone outlines it), or the subject or people, or shapes and ranges of tone and colour, joined and cut as needed, and draws by hand what is left. It changes exposure, contrast, colour and clarity inside, and checks every mask before using it.
- **Film grain and halation.** Grain that scales with the photo and is strongest in the midtones, and the red glow film shows around bright light.
- **Styles.** A look you can put on any photo. Save one from a photo you like with the Styles button beside the composer, where each of your styles is shown tried on the photo; or make one on the home screen from a picture whose look you love (add its original too and Oscuru learns exactly what the edit changed). Tap a style on the home screen, then the photos it goes on; or ask the assistant.
- **Share.** One button: the developed photo as a full-size JPEG, or the original file untouched (a RAW stays RAW). From a photo, or from a selection in the library.
- **Real RAW development, ours.** Apple ProRAW, DNG and the camera RAW formats iOS reads, plus JPEG and HEIC, developed on the phone with Core Image. Apple's decoder only does the maths the file dictates; its tone curve, noise reduction and sharpening are off, and Oscuru's own base curve keeps the light as measured. Originals are never changed. Export at full resolution to JPEG or HEIC.
- **Your model, your account.** The assistant runs on any OpenRouter model that reads images and calls tools, with your own sign-in. The app records what it costs and sets no limits of its own.

## How it's built

A native iPhone app: Swift, SwiftUI, Core Image and JavaScriptCore. No server, no web views, no React Native.

```
ios/App                         SwiftUI app: library, the photo screen, styles, camera, settings
ios/Packages/OscuruKit
  OscuruCore                    editing state, colour pipeline, styles, the transcript, the agent loop,
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
