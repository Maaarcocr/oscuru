# AGENTS.md

## Project summary

Oscuru is a RAW photo editor for iPhone built with Expo (SDK 58, React Native, TypeScript) and one local Swift module. An AI assistant edits photos by writing JavaScript for a single tool; the phone runs the scripts in a sandbox and renders with Core Image. There is no server: the model is reached through OpenRouter with the person's own key.

Status: first prototype (0.1).

## Source-of-truth documents

- `docs/architecture.md`: how it is built and why.
- `docs/photo-api.d.ts`: the scripting API, generated from `src/script/apiDeclarations.ts` (`npm run sync-api-docs`).
- `docs/expo.md`: builds, TestFlight and over-the-air updates with Expo.
- `AGENTS.md` (this file): how to work here.

Expo changes with every SDK. Before touching an Expo, EAS or React Native API, read the installed package's types or the versioned docs (`https://docs.expo.dev/versions/v58.0.0/`, index at `https://docs.expo.dev/llms.txt`) rather than relying on memory. Add packages with `npx expo install`.

## Non-negotiable rules

- **No generated pixels.** The assistant sets development parameters. Never add a feature that synthesizes, inpaints or replaces image content.
- **One tool.** The agent has `execute_edit_script` and nothing else. New abilities are new members of the `photo` API, documented in `apiDeclarations.ts`, not new tools.
- **One editing path.** Sliders, undo and scripts all go through `EditorSession` and the functions in `src/engine/state.ts`. Do not add a second way to change or render a photo.
- **Scripts are untrusted.** They run only in the interpreter in `src/script`, never with `eval` or `new Function`. Everything a script can reach is an own property of what `photoApi.ts` hands in. Keep the `'use strict'` directives in the interpreter files.
- **The original file is never written.**
- **The model is replaceable.** Nothing outside `src/agent/openrouter.ts` knows the provider's wire format; nothing in `src/agent` knows about rendering.
- **English and Italian.** Every user-facing string is a key in `src/i18n/en.ts` and `src/i18n/it.ts`; a test checks they match.
- **Privacy.** No analytics, crash reporting or third-party SDKs. The API key stays in the keychain and goes only to OpenRouter.

## Keep it simple

Plain, standard code with few moving parts. Stock React Native controls, one small theme file, no state library (stores are `src/platform/store.ts`). The mapping from photographic settings to filter amounts lives in TypeScript (`src/engine/recipe.ts`, `src/engine/color.ts`) so it can be tested here and changed with an over-the-air update; the Swift side only applies what it is given.

## Commands

```sh
npm run check                      # typecheck, lint, unit tests
npm run sync-api-docs              # after changing the scripting API
npx expo export --platform ios     # the bundle CI builds
npx expo start --web               # browser preview (canvas stand-in for the engine)

# macOS only
swift test --package-path modules/oscuru-engine/native-tests
npx expo prebuild --platform ios && xcodebuild ...   # see .github/workflows/ci.yml
```

## Testing expectations

- Change the editing state or a setting's range: update `src/engine/state.ts`, its tests, and regenerate the API docs.
- Change the pipeline's point operations (`color.ts`): tests there. Change what the Swift engine does: `native-tests`, which run on macOS in CI and pin down table layouts, colour spaces and directions.
- Change the `photo` API: `src/script/__tests__/execute.test.ts` (it also checks the declarations list exactly the members that exist).
- Change the agent loop: `src/editor/__tests__/session.test.ts`, with the played-back model.
- The simulator job launches the app with `-oscuruSelfTest YES` (`src/platform/selfTest.ts`): keep it passing; it is the only test of the sandbox on Hermes and of the JavaScript-to-Swift bridge.

## Git

- Never commit signing material (`*.p12`, `*.p8`, `*.mobileprovision`, `credentials.json`), an OpenRouter key, or the generated `ios/` directory.
- `*.web.ts` files are the browser preview's stand-ins. They must keep the same exports as the file they replace.
