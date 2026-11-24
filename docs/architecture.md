# Architecture

Oscuru is a native iPhone app. This page says how the parts fit and why.

## The loop

```
person: "make it cinematic, recover the sky"
   │
   ▼
Agent.run (OscuruCore)  ── HTTPS ──▶  model on OpenRouter
   │   sends: the instruction, settings, metadata, statistics, saved filters,
   │          the photo (and the original, when it has been edited)
   │   receives: execute_edit_script({ sessionId, baseRevision, code })
   ▼
EditorPort (app)                checks the session and revision
   ▼
ScriptRuntime (JavaScriptCore)  runs the script in this photo's REPL context;
   │                            photo.current.adjust(…), curves.set(…), getStatistics(), photo.show(…)
   ▼
EditHistory                     the result becomes the photo's settings: one undo step, revision + 1
   ▼
Engine (Core Image)             renders the photo
   ▼
tool result: what changed, the script's value and logs, statistics,
             and pictures: before this request's edits, after, and anything photo.show() asked for
   ▼
the model looks, and runs another script or writes its closing note
```

The loop has no limits: no cap on scripts, no spending limit, no timeout on requests. It ends when the model replies without calling the tool, or when the person taps Stop.

## Editing state

`EditingState` holds the whole development as plain data: global adjustments, four curves, eight HSL ranges, three-way grading, detail, grain, halation, local adjustments, crop. A local adjustment is a named mask (a radial or linear area, the subject or people, or the whole frame; optionally inverted and narrowed to a luminance or hue range) with exposure, contrast, highlights, shadows, white balance shift, saturation, clarity and dehaze for inside it. Positions are fractions of the cropped frame, so they match the pictures the model sees. Every change goes through a function that validates it, so an invalid state cannot exist, and the same checks serve scripts, saved documents and filters. Ranges and descriptions live in one table per group (`Specs`); the API documentation given to the model is generated from them.

`EditHistory` is the only way the photo changes. Every change (a script, undo, a filter, a reset) is a step and gives a new revision. A script names the revision it was written against and is refused if the photo has moved on, with the current state and picture in the reply.

## Rendering

`OscuruEngine` decodes and renders with Core Image. In order:

1. **Develop**, in linear light: for RAW files `CIRAWFilter` applies exposure, white balance, noise reduction and sharpening inside the decoder. Apple's looks in the decoder are switched off (no boost tone curve, local tone mapping, noise reduction or sharpening unless asked for), so it does only what the file's own numbers decide: demosaicing, the camera's colour matrix and white balance, the lens corrections in the file, and fitting colours into range. Its linear output then gets Oscuru's base curve (`ColorPipeline.baseCurve`): the identity up to 0.75 of white, then a smooth exponential roll-off towards white. Every other choice about the look is made in the conversation. The developed photo at preview size is cached, so tone and colour changes do not decode again.
2. **Local recovery** (highlights and shadows) and **local contrast** (clarity and texture, radius relative to the photo).
3. **Tone stage**: a per-channel 1D table. 4. **Colour stage**: a 33³ cube. Both are computed in `ColorPipeline` (pure Swift, unit-tested on Linux) and applied in gamma-encoded Display P3.
5. **Halation**: luminance above a threshold, tinted red-orange, blurred and screened on top.
6. **Geometry**: flips, quarter turns, straightening, crop.
7. **Local adjustments**, in order: each adjusts the whole frame (white balance gains, a tone table, saturation, clarity) and blends it in through its mask. Radial and linear areas are Core Image gradients; tone and colour ranges are a colour cube computed in `ColorPipeline` and evaluated on the photo before that adjustment; the subject and people come from Vision (`VNGenerateForegroundInstanceMaskRequest`, `VNGeneratePersonSegmentationRequest`) run once per open photo on a small development, then put through the same geometry as the photo.
8. **Vignette**. 9. **Grain**: a fixed noise pattern (`CIRandomGenerator`) at a size relative to the frame, two layers mixed by roughness, overlaid in encoded values so it is strongest in the midtones; grains finer than a pixel are weakened as a downscale would.

Everything here is programmatic image processing; nothing uses generative models.

The screen gets Display P3; the model gets sRGB JPEGs (models read sRGB; a wide-gamut file would look washed out to them); exports are full-resolution Display P3 JPEG or HEIC with the capture details carried over. Statistics are measured on a small sRGB bitmap.

## Scripting

Each open photo has one JavaScriptCore context, kept between scripts: a REPL. `var`, functions and `globalThis` persist; each script is wrapped in a block so `let`/`const` do not collide between calls. The context gets two globals, `photo` and `console`, built in a small prelude over a single native function. Nothing else from the app is reachable.

A script works on a draft of the settings. Statistics inside a script reflect its own changes so far (rendered on demand), and `photo.show()` queues pictures — current, before this request, or the original, optionally zoomed into a region. When the script ends normally its draft becomes the photo's settings; if it throws, nothing changes.

There is no time limit. When the person stops the assistant, every API call throws at once; a script stuck in a loop that never calls the API is abandoned with its context, and the next script starts with a fresh one.

## Agent

`Agent.run` carries out one instruction. It returns the conversation to continue from; a cancelled turn returns the conversation as it was. Within an instruction every picture stays, so the model can compare every step; before a new instruction, pictures from earlier ones are replaced by a note except the latest set.

It depends on two small protocols, `ModelClient` and `AgentPort`. That is the seam for moving orchestration to a server later.

## Camera

`Camera` (app) asks AVFoundation for RAW only: `AVCapturePhotoSettings(rawPixelFormatType:)` with a Bayer format, no processed image, ProRAW off. Apple's photo processing (Smart HDR, Deep Fusion, night mode, multi-frame fusion, its noise reduction and sharpening) only runs on processed photos, so none of it touches the shot. It uses one physical lens at a time, as Bayer RAW comes from a single sensor; lenses that offer no Bayer format are left out. Bayer RAW is the sensor's binned 12 MP readout; 48 MP is only available as ProRAW, which is processed. Each shot goes into the library as a DNG through the same `Library.add` as an import, and is developed by the engine like any other RAW. The viewfinder is AVFoundation's ordinary preview, so it looks more finished than the shot. In UI tests the sample photo stands in for the lens.

## Looks from pictures

Up to two pictures can be attached to an instruction. They are kept in the photo's folder (`references/`), opened in the engine for the length of that instruction, and shown to the model. `LookFitting` (in `OscuruCore`, tested on Linux) works on small Display P3 bitmaps, the space the tone and colour stages use: `fit` compares an original (a reference, or the open photo without its tone and colour settings) with its edit point by point and takes, per channel, the median of what each value became as a curve, then searches the saturation that brings the rest closest; `match` maps each channel's quantiles onto a reference's. Either result is applied with `applyLook`, which replaces the tone and colour stages and keeps exposure, white balance and the rest.

## Filters

A filter is the look of a photo: tone, colour, curves, HSL, grading. Crop and detail stay with the photo they were made on. White balance is stored as a shift from the as-shot value, so a warm filter stays warm on a photo taken in different light. Filters are saved, applied, renamed and deleted from the filter sheet, and scripts reach them through `photo.filters`.

## Accounts and cost

There is no Oscuru server. The person signs in to OpenRouter (OAuth PKCE) or pastes a key; the key lives in the keychain. Every response carries what it cost; `UsageLedger` records it per user, instruction and photo, and Settings shows today, this month and in total. Oscuru never limits spending; a cap, if wanted, is set on the key at openrouter.ai.

## Storage

Each photo has a folder in the app's documents: the copied original, `doc.json` (what the engine reported, the editing state, its revision) and a thumbnail. Filters, settings and the usage record are JSON files next to them.

## Tests

- `OscuruCoreTests` (Linux and macOS): state, colour pipeline, statistics, filters, history, the agent loop with a played-back model, the OpenRouter client, and that `docs/photo-api.d.ts` is current.
- `OscuruEngineTests` (macOS): what the TypeScript-era port assumes about Core Image — table layouts, colour spaces, rotation and white-balance directions, regions, exports, and that RAW files go through the RAW decoder.
- `OscuruScriptingTests` (macOS): the JavaScriptCore environment — the API, the REPL, `photo.show`, filters, errors, cancellation, abandoned loops.
- `OscuruUITests` (simulator, English and Italian): the whole flow against a sample photo and a played-back model.
