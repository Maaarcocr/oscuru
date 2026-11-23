<h1 align="center">Oscuru</h1>

<p align="center">
  A RAW photo editor for iPhone where an AI assistant edits by programming the darkroom, not by generating pixels.<br>
  English · Italiano
</p>

---

Oscuru ("dark" in Sicilian) develops your RAW photos on the phone with ordinary photographic controls: exposure, white balance, tone curves, HSL, colour grading, detail, crop. You can move every control yourself. Or you can describe what you want, and an assistant gets there with the same controls.

The assistant never produces or alters image content. A remote model looks at a preview, writes a short JavaScript program against a documented photo API, and the phone runs it. The program sets development parameters; the phone's RAW engine renders them. The model looks at the result and refines it. Everything it did shows up in your sliders and curves, as undo steps.

## What it does

- **RAW development on the phone.** Apple ProRAW, DNG and the camera RAW formats iOS can read, plus JPEG and HEIC. Originals are copied into the app and never written again.
- **A full manual editor.** Light, Colour, Curves (master and per channel), HSL, Colour grading, Detail, Crop and straighten, histogram with clipping indicators, before/after, undo/redo. It works offline.
- **An assistant with one tool.** `execute_edit_script` takes JavaScript. Scripts run in a sandbox on the phone, as a transaction: commit and it is one undo step, throw and nothing changed.
- **Your model, your account.** The assistant reaches a model through OpenRouter with your own sign-in or key. Any model that reads images and calls tools works. Spending is recorded per user and capped per request, per day and per month.
- **Full-resolution export** to JPEG or HEIC through the share sheet.

## How it's built

```
remote model (OpenRouter) ── one tool: execute_edit_script(sessionId, baseRevision, code)
                                   │
src/agent      agent loop, OpenRouter client, cost ledger and limits
src/script     sandboxed JavaScript interpreter, the `photo` API, transactions
src/editor     one editing session: state, revisions, history, rendering
src/engine     editing state, tone tables and colour cube, statistics (pure TypeScript)
modules/oscuru-engine   Swift: RAW decoding and the Core Image pipeline
src/ui, src/app          screens (Expo Router, React Native)
```

Details: **[docs/architecture.md](docs/architecture.md)**. The scripting API the assistant is given: **[docs/photo-api.d.ts](docs/photo-api.d.ts)**. Building and publishing with Expo: **[docs/expo.md](docs/expo.md)**.

## Working on it

```sh
npm ci
npm run check          # types, lint, all unit tests
npx expo start --web   # the screens in a browser, with a canvas stand-in for the engine
```

The real app needs its own build (it has native code, so Expo Go cannot run it): see [docs/expo.md](docs/expo.md). CI builds it for the simulator on every push and runs a self-test of the sandbox and the engine there.

## Privacy

No account, no server, no analytics. Photos and edits stay on the phone. When you use the assistant, a preview of the photo, its settings and its capture details go to OpenRouter and the model you chose, under your own OpenRouter account. Your key is kept in the keychain.

## Licence

AGPL-3.0. See [LICENSE](LICENSE).
