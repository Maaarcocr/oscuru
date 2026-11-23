# Architecture

Oscuru is an Expo app (SDK 58, React Native on Hermes, TypeScript) with one local Swift module. This page says how the parts fit and why each choice was made. Where the original specification asked for something different, the difference is called out.

## The loop

```
person: "make it cinematic, recover the sky"
   │
   ▼
agent loop (src/agent/agent.ts)  ── HTTPS ──▶  model on OpenRouter
   │   sends: instruction, settings, metadata, statistics, a rendered preview
   │   receives: execute_edit_script({ sessionId, baseRevision, code })
   ▼
EditorSession.runScript (src/editor/session.ts)
   │   checks the session and revision
   ▼
sandbox (src/script)            the script calls photo.current.adjust(…), curves.set(…), commit()
   │   on a draft of the editing state; a throw discards everything
   ▼
editing state (src/engine/state.ts)   one new undo step, revision + 1
   ▼
renderer (modules/oscuru-engine, Swift + Core Image)   preview + a small bitmap for statistics
   ▼
tool result: changes, logs, statistics as JSON, and the new preview as an image
   ▼
the model looks, and either sends another script or writes its closing note
```

## Editing state

`src/engine/state.ts` defines the whole state as plain data: global adjustments, four curves, eight HSL ranges, three-way grading, detail, crop. Every change goes through a function that validates and returns a new state, so an invalid state cannot exist, and the same checks serve the sliders, saved documents and scripts. The parameter vocabulary follows Camera Raw; the rendering semantics are Oscuru's own.

Ranges, defaults and descriptions live in one table per group (`GLOBAL_SPECS` and friends). The sliders, the validators and the API documentation given to the model are all generated from those tables.

## Rendering

RAW decoding and everything that needs neighbouring pixels is native (`modules/oscuru-engine/ios/Engine`, Core Image). The order is:

1. **Develop**, in linear scene-referred light: for RAW files `CIRAWFilter` applies exposure, white balance, noise reduction and sharpening inside the decoder; other files get the equivalent filters on linearized data.
2. **Local recovery**: the recovering directions of highlights and shadows (`CIHighlightShadowAdjust`), then clarity and texture as unsharp masks whose radius is a fraction of the long edge, so previews match exports.
3. **Tone stage**: a per-channel 1D table. 4. **Colour stage**: a 33³ cube. Both are computed in TypeScript (`src/engine/color.ts`) and applied in gamma-encoded Display P3.
5. **Geometry**: flips, quarter turns, straightening, crop. 6. **Vignette**. 7. **Output** to JPEG/HEIC, plus a small sRGB bitmap that `src/engine/stats.ts` turns into the histogram and statistics.

The working space is extended linear sRGB in half floats. A developed RAW at preview size is cached, so moving a tone or colour control does not decode the file again.

Why tables: the point operations (contrast, curves, HSL, grading…) are where the photographic character is, and as TypeScript they are unit-tested on any machine and can change with an over-the-air update. The Swift side stays small and only applies what it is given. `native-tests` (run with `swift test` on macOS in CI) pin down what the TypeScript assumes about Core Image: table layouts, colour spaces, rotation and white-balance directions, and that RAW files really go through the RAW decoder.

**Differences from the specification.** The UI is React Native rather than SwiftUI, because the app is built and published with Expo. There are no hand-written Metal kernels yet: the pipeline is built from Core Image's own filters and lookup tables. Dehaze is a global approximation, and masks are not implemented.

## Scripting

**The runtime is an interpreter, not JavaScriptCore.** The specification proposed JavaScriptCore and noted it should not be assumed to be a security boundary or to enforce hard limits. `src/script/interpreter.ts` is a small JavaScript interpreter (parsing with acorn) that runs inside the app's own JavaScript engine. That gives:

- a real boundary: a script can only reach what it is handed (`photo`, `console`, and allow-listed standard helpers). There is no path to the global object, `Function`, the network or the file system, because property access itself is interpreted and guarded;
- hard limits that do not depend on the engine: a step budget, a wall-clock limit, call depth, collection sizes, an allocation budget, and cooperative cancellation. Limit and security errors cannot be caught by the script;
- an answer to App Store rule 2.5.2: downloaded text is interpreted against a fixed API of existing features, not compiled or executed as native code;
- testability: the sandbox has about a thousand tests that run in CI, including a table of escape attempts.

The language is a pragmatic modern subset (const/let, functions, closures, destructuring, loops, Math, JSON, arrays, objects, Map/Set). Classes, async, regular expressions and modules are rejected before anything runs.

**The API** is `photo.current` (`src/script/photoApi.ts`). Its contract is `src/script/apiDeclarations.ts`, written out as [`photo-api.d.ts`](photo-api.d.ts); a test checks that the declarations list exactly the members the runtime provides.

**Transactions** (`src/script/execute.ts`). A script works on a draft. `commit()` marks the draft as the result; if the script then finishes normally, the draft becomes the photo's state as one undo step. If it throws, breaks a limit or is cancelled, nothing changes. Statistics available inside a script describe the photo as rendered at the script's base revision; fresh ones come back with the tool result.

**Revisions.** Every committed change, manual or scripted, increases the revision. A script names the revision it was written against and is refused if the photo has moved on, with the current state and preview in the reply, so the model starts again from what the person did instead of overwriting it. A slider that is still being dragged counts as a change.

## Agent

`src/agent/agent.ts` runs one instruction: build the user message (instruction, context JSON, preview), call the model with the single tool, execute tool calls through an `AgentPort`, append results and the new preview, repeat until the model answers without a tool call or a limit stops it. It knows nothing about rendering; `src/editor/agentPort.ts` is the phone's side.

The loop runs in the app in this prototype, talking straight to OpenRouter. It only depends on two small interfaces (`OpenRouterClient`, `AgentPort`), which is the seam for moving orchestration to a server later: the server would run the same loop and reach the phone's `AgentPort` over a socket.

Previews are sent as sRGB JPEGs (1024 px by default); only the two most recent stay in the conversation. A cancelled or failed turn is removed from the conversation, so the next one starts clean. Edits already applied stay, and can be reverted per instruction.

## Accounts, cost and limits

There is no Oscuru server. The person signs in to OpenRouter (OAuth PKCE; the key OpenRouter issues is proposed with the monthly limit as its own cap) or pastes a key. The key is stored in the keychain.

"Cost per user" is therefore cost per OpenRouter account. Every model response carries what it cost; `src/agent/cost.ts` records it per user, instruction and photo, and the agent checks three limits before every request: per instruction, per day, per month. The settings screen shows the app's own record and what OpenRouter reports for the key.

**If Oscuru later pays for usage itself**, the same pieces apply with one addition: a small server holding an OpenRouter management key that creates one key per user with a spending limit (OpenRouter enforces it) and hands it to the app after sign-in. The app would not change beyond where the key comes from.

## Storage

Each photo has a folder in the app's documents directory: the copied original, a JSON document (what the engine reported, the editing state, its revision) and a thumbnail. History and the conversation live in memory while the photo is open.

## Browser preview

`npx expo start --web` runs the same screens in a browser. `modules/oscuru-engine/index.web.ts` is a canvas stand-in for the engine and `*.web.ts` files replace the storage layer. It exists to work on the interface without a phone; it reads no RAW files and only approximates the rendering.
