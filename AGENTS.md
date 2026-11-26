# AGENTS.md

## Project summary

Oscuru is a native iPhone RAW photo editor (Swift, SwiftUI, Core Image, JavaScriptCore; iOS 27+). There are no manual editing controls: the person describes what they want and a remote model edits the photo by writing JavaScript for one tool, `execute_edit_script`. The phone runs the scripts and renders with its own engine. There is no server: the model is reached through OpenRouter with the person's own key.

Status: first prototype (0.1).

## Source-of-truth documents

- `docs/architecture.md`: how it is built and why.
- `docs/photo-api.d.ts`: the scripting API, generated from `OscuruCore/PhotoAPI.swift` (`UPDATE_API_DOCS=1 swift test`).
- `docs/expo.md`: building and publishing with Expo's build service.
- `AGENTS.md` (this file): how to work here.

## Product rules (from the owner)

- **Simple and AI-driven.** The editor is the photo and a prompt. Do not add sliders, curve editors or other manual controls; this is not Lightroom.
- **Few screens, nothing twice.** Home is styles, photos and the camera; photos chosen there are shared, saved, combined into a collage or deleted. A photo is its conversation, a composer with Styles beside it, and Save and Share. A feature gets one place, where it is used, in plain sight; no menus of extras, no second entry point for the same thing.
- **The camera shoots RAW, two ways, and the person chooses.** Zero processing (the default) is Bayer RAW and nothing else, each lens at its own zoom: one frame, unless the person has turned on Frames in Settings and raised it in the camera. Then that many RAW frames are taken (at one exposure or bracketed, back to back or spaced, as the person set beside the frames dial), merged into one RAW file the camera's own way (`FrameSet.make`: lined up and averaged around the sharpest, movement frozen) with nothing more done to it (no smoothing within a frame, no sharpening, no tone), and kept beside it. How kept frames are merged after that is a photo setting the assistant changes in the conversation (`EditingState.frames`: which frames, how they are lined up, how each place is made from them, onto what grid), never a control on a screen. Keep it a few independent choices that combine, not a list of effects. ProRAW is Apple's processed RAW at the sensor's full size, and only there does the viewfinder zoom between lenses: the shot is the lens's whole frame and the zoom is the crop the photo starts with (`PhotoDefaults.framing`). Do not add processed (JPEG/HEIC) capture, merging decided anywhere else, or looks applied at capture; development happens in the conversation.
- **The exposure is the photographer's.** Aperture (where the lens has one), time, ISO and focus are each the camera's until set by hand on its dial, in any mix, and what is set is what is shot: never let the capture use a time or an ISO of its own for a shot whose values were set. The line of values, the histogram and the stripes on blown highlights are always on screen. The camera is the one place with manual controls; editing stays a conversation.
- **No limits on the assistant.** No cap on scripts per request, no spending limits, no request timeouts, no token caps. Record what it costs; never stop it for cost or time. Only the person stops it.
- **The assistant sees its work.** After every script that changes the photo it gets the picture before and after; scripts can ask for more with `photo.show()`. Keep that.
- **The scripting environment is a REPL.** One JavaScriptCore context per open photo, kept between scripts.
- **No AI image generation.** The assistant never generates, paints or replaces image content with a generative model, and nothing adds what the camera did not record. Any programmatic image processing is fine: development, film grain, halation, masks and local adjustments, on-device image analysis to find a subject or people. Scripts set parameters; the engine renders them.
- **One tool.** New abilities are new members of the `photo` API (documented in `PhotoAPI.swift`), not new tools.

## Engineering rules

- **One way to do each thing.** One editing path (`PhotoEditor.set`), one history (the transcript), one way to get pictures of a photo (`PhotoRenderer`), one way to turn a style into settings (`Style.applied`), one way out of the app (`AppModel.export`, which saving to Photos builds on), and on screen one Save button, one Share button, one style tile and one naming alert. Before adding a second way to do something, change the first.
- **The transcript is the conversation.** A photo's thread and what the model is told are read from its append-only `Transcript`; nothing is kept beside it, and every step is written before it is shown. The loop starts from whatever the transcript says, so it can always pick up where it stopped (see `docs/architecture.md`, Agent).
- **Scripts reach only `photo` and `console`.** All of the API goes through the single native bridge in `ScriptRuntime`.
- **The original file is never written.** Neither are a shot's kept frames; a merge of them is a file of its own.
- **The model is replaceable.** Only `OpenRouter.swift` knows the wire format; `Agent.swift` knows nothing about rendering.
- **English and Italian.** Every user-facing string goes through `ios/App/Sources/Support/L10n.swift` with both languages in `Localizable.xcstrings`; `scripts/check-strings.py` enforces it.
- **Privacy.** No analytics, crash reporting or third-party SDKs.
- Stock SwiftUI, plain code, few moving parts.

## Commands

```sh
./scripts/fetch-models.sh                               # the on-device models (about 100 MB, not in git); builds call it
swift test --package-path ios/Packages/OscuruKit        # Linux runs OscuruCore; macOS also the engine and scripting
UPDATE_API_DOCS=1 swift test --package-path ios/Packages/OscuruKit   # after changing the photo API
python3 scripts/check-strings.py
(cd ios && xcodegen generate)
./scripts/test-ios.sh                                    # macOS: UI tests in English and Italian
```

## Testing expectations

- Change the editing state, the colour pipeline, styles, the transcript or the agent loop: `OscuruCoreTests`.
- Change what Core Image does: `OscuruEngineTests` (they pin table layouts, colour spaces, directions, RAW decoding).
- Change the scripting environment or the photo API: `OscuruScriptingTests`.
- New user-facing flows: extend `OscuruUITests` (it runs against a sample photo and a played-back model, `-ui-testing`), finding elements by accessibility identifier.

## Git

- Never commit signing material, an OpenRouter key, or the generated `ios/Oscuru.xcodeproj`.
