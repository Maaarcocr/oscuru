# AGENTS.md

## Project summary

Oscuru is a native iPhone RAW photo editor (Swift, SwiftUI, Core Image, JavaScriptCore; iOS 26+). There are no manual editing controls: the person describes what they want and a remote model edits the photo by writing JavaScript for one tool, `execute_edit_script`. The phone runs the scripts and renders with its own engine. There is no server: the model is reached through OpenRouter with the person's own key.

Status: first prototype (0.1).

## Source-of-truth documents

- `docs/architecture.md`: how it is built and why.
- `docs/photo-api.d.ts`: the scripting API, generated from `OscuruCore/PhotoAPI.swift` (`UPDATE_API_DOCS=1 swift test`).
- `docs/expo.md`: building and publishing with Expo's build service.
- `AGENTS.md` (this file): how to work here.

## Product rules (from the owner)

- **Simple and AI-driven.** The editor is the photo and a prompt. Do not add sliders, curve editors or other manual controls; this is not Lightroom.
- **No limits on the assistant.** No cap on scripts per request, no spending limits, no request timeouts, no token caps. Record what it costs; never stop it for cost or time. Only the person stops it.
- **The assistant sees its work.** After every script that changes the photo it gets the picture before and after; scripts can ask for more with `photo.show()`. Keep that.
- **The scripting environment is a REPL.** One JavaScriptCore context per open photo, kept between scripts.
- **No generated pixels.** Scripts set development parameters only.
- **One tool.** New abilities are new members of the `photo` API (documented in `PhotoAPI.swift`), not new tools.

## Engineering rules

- **One editing path.** Every change to a photo goes through `EditHistory` in `PhotoEditor`; every change gives a new revision, and scripts against an old revision are refused.
- **Scripts reach only `photo` and `console`.** All of the API goes through the single native bridge in `ScriptRuntime`.
- **The original file is never written.**
- **The model is replaceable.** Only `OpenRouter.swift` knows the wire format; `Agent.swift` knows nothing about rendering.
- **English and Italian.** Every user-facing string goes through `ios/App/Sources/Support/L10n.swift` with both languages in `Localizable.xcstrings`; `scripts/check-strings.py` enforces it.
- **Privacy.** No analytics, crash reporting or third-party SDKs.
- Stock SwiftUI, plain code, few moving parts.

## Commands

```sh
swift test --package-path ios/Packages/OscuruKit        # Linux runs OscuruCore; macOS also the engine and scripting
UPDATE_API_DOCS=1 swift test --package-path ios/Packages/OscuruKit   # after changing the photo API
python3 scripts/check-strings.py
(cd ios && xcodegen generate)
./scripts/test-ios.sh                                    # macOS: UI tests in English and Italian
```

## Testing expectations

- Change the editing state, the colour pipeline, filters, history or the agent loop: `OscuruCoreTests`.
- Change what Core Image does: `OscuruEngineTests` (they pin table layouts, colour spaces, directions, RAW decoding).
- Change the scripting environment or the photo API: `OscuruScriptingTests`.
- New user-facing flows: extend `OscuruUITests` (it runs against a sample photo and a played-back model, `-ui-testing`), finding elements by accessibility identifier.

## Git

- Never commit signing material, an OpenRouter key, or the generated `ios/Oscuru.xcodeproj`.
