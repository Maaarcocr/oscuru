# Architecture

Oscuru is a native iPhone app. This page says how the parts fit and why.

## The loop

```
person: "make it cinematic, recover the sky"
   │
   ▼
Agent.run (OscuruCore)  ── HTTPS ──▶  model on OpenRouter
   │   reads the photo's transcript; writes every step to it before going on
   │   sends: the instruction, settings, metadata, statistics, saved styles,
   │          the photo (and the original, when it has been edited)
   │   receives: execute_edit_script({ code })
   ▼
ScriptRuntime (JavaScriptCore)  runs the script in this photo's REPL context;
   │                            photo.current.adjust(…), curves.set(…), getStatistics(), photo.show(…)
   ▼
PhotoEditor.set (app)           the result becomes the photo's settings, and goes into the
   │                            transcript with the script's report
   ▼
Engine (Core Image)             renders the photo
   ▼
tool result: what changed, the script's value and logs, statistics,
             and pictures: before this request's edits, after, and anything photo.show() asked for
   ▼
the model looks, and runs another script or writes its closing note
```

The loop has no limits: no cap on scripts, no spending limit, no timeout on requests. It ends when the model replies without calling the tool, when the person taps Stop, or when a request fails in a way retrying cannot fix.

## Editing state

`EditingState` holds the whole development as plain data: global adjustments, four curves, eight HSL ranges, three-way grading, detail, grain, halation, local adjustments, crop. A local adjustment is a named mask (areas joined together, with others cut out or intersected: an object selected by tapping points, the subject or people, a radial or linear area, the whole frame, or an outline or brush strokes drawn by hand; optionally inverted, narrowed to a luminance or hue range measured on the photo as it is or as developed before tone and colour, grown or shrunk, and snapped to edges) with exposure, contrast, highlights, shadows, white balance shift, saturation, clarity and dehaze for inside it. Positions are fractions of the cropped frame, so they match the pictures the model sees. Every change goes through a function that validates it, so an invalid state cannot exist, and the same checks serve scripts, saved documents and filters. Ranges and descriptions live in one table per group (`Specs`); the API documentation given to the model is generated from them.

The transcript is the photo's history (see Agent): the photo's settings now are the latest it recorded, and every version in it can be shown again and restored. Everything that changes the photo (a script, a style, restoring a version) goes through `PhotoEditor.set` and is written there. `doc.json` keeps a copy of the current settings so the library can show and export photos without opening their conversations.

## Rendering

`OscuruEngine` decodes and renders with Core Image. In order:

1. **Develop**, in linear light: for RAW files `CIRAWFilter` applies exposure, white balance, noise reduction and sharpening inside the decoder. Apple's looks in the decoder are switched off (no boost tone curve, local tone mapping, noise reduction or sharpening unless asked for), so it does only what the file's own numbers decide: demosaicing, the camera's colour matrix and white balance, the lens corrections in the file, and fitting colours into range. Its linear output then gets Oscuru's base curve (`ColorPipeline.baseCurve`): the identity up to 0.75 of white, then a smooth exponential roll-off towards white. Every other choice about the look is made in the conversation. The developed photo at preview size is cached, so tone and colour changes do not decode again.
2. **Local recovery** (highlights and shadows) and **local contrast** (clarity and texture, radius relative to the photo).
3. **Tone stage**: a per-channel 1D table. 4. **Colour stage**: a 33³ cube. Both are computed in `ColorPipeline` (pure Swift, unit-tested on Linux) and applied in gamma-encoded Display P3.
5. **Halation**: luminance above a threshold, tinted red-orange, blurred and screened on top.
6. **Geometry**: flips, quarter turns, straightening, crop.
7. **Local adjustments**, in order: each adjusts the whole frame (white balance gains, a tone table, saturation, clarity) and blends it in through its mask. Radial and linear areas are Core Image gradients; tone and colour ranges are a colour cube computed in `ColorPipeline` and evaluated on the photo before that adjustment; the subject and people come from Vision (`VNGenerateForegroundInstanceMaskRequest`, `VNGeneratePersonSegmentationRequest`) run once per open photo on a small development, then put through the same geometry as the photo. A tapped object comes from Segment Anything 2.1 tiny in Apple's Core ML conversion (`Segmenter`; fetched by `scripts/fetch-models.sh`, pinned and checksummed, and bundled compiled): its image encoder reads the small development, framed as the photo is, once per framing; each set of points then costs only the prompt encoder and mask decoder, and the result is kept. Its 256×256 logits are stretched over the frame with an edge about one logit wide. A depth range comes from Depth Anything V2 small, 8-bit, in Apple's Core ML conversion (`DepthEstimator`, fetched the same way): it reads the small development once per open photo, uncropped and stretched to its fixed 518×392 input, and its inverse depth becomes `DepthMap`, 0 for the nearest part of the photo and 1 for the farthest (the nearest and farthest hundredth clipped), so a crop never changes the scale. The band's weight is worked out on that small map, stretched over the picture and put through the photo's geometry; `photo.show("depth")` shows the map itself as greys. Outlines and brush strokes are drawn with Core Graphics and softened. Joined areas take the maximum (never doubled), intersections the minimum, cut-outs multiply by the inverse; `grow` is a morphology filter and `refine` a guided filter that follows the photo's own edges. The models only find what is in the photo; nothing generates pixels.
8. **Vignette**. 9. **Grain**: a fixed noise pattern (`CIRandomGenerator`) at a size relative to the frame, two layers mixed by roughness, overlaid in encoded values so it is strongest in the midtones; grains finer than a pixel are weakened as a downscale would.

Everything here is programmatic image processing; nothing uses generative models.

The screen gets Display P3; the model gets sRGB JPEGs (models read sRGB; a wide-gamut file would look washed out to them); exports are full-resolution Display P3 JPEGs with the capture details carried over (or the original file, untouched). Statistics are measured on a small sRGB bitmap.

Photos render at the same time as each other; each photo renders one thing at a time (`Engine.using`). Full-size work (exports, the assistant's zoomed-in pictures) runs one thing at a time across all photos and clears Core Image's cache after it, so two such renders never need their memory at the same moment. In the app, every render goes through `Rendering`, a serial lane per photo on threads of its own, never Swift's few worker threads: a render waiting for its photo there would hold a worker thread, and once they are all held the whole app stalls. Work its caller has stopped waiting for is dropped before it starts. Every picture is checked as it is drawn (`CIContext.draw(_:into:)`), because Core Image fails silently, leaving black, when the graphics processor will not draw: when it is out of memory, or when the app is in the background, which iOS forbids. A failed render is an error, never a black picture kept and shown from then on. While the app is in the background, the engine draws on the processor instead. A preview's development is kept only up to 3072 pixels on its long edge (closely cropped photos develop more than that, for each render), so an open photo holds tens of megabytes, not hundreds.

## Scripting

Each open photo has one JavaScriptCore context, kept between scripts: a REPL. `var`, functions and `globalThis` persist; each script is wrapped in a block so `let`/`const` do not collide between calls. The context gets two globals, `photo` and `console`, built in a small prelude over a single native function. Nothing else from the app is reachable.

A script works on a draft of the settings. Statistics inside a script reflect its own changes so far (rendered on demand), and `photo.show()` queues pictures — current, before this request, or the original, optionally zoomed into a region. When the script ends normally its draft becomes the photo's settings; if it throws, nothing changes.

There is no time limit. When the person stops the assistant, every API call throws at once; a script stuck in a loop that never calls the API is abandoned with its context, and the next script starts with a fresh one.

## Agent

The assistant's loop follows [pi](https://github.com/earendil-works/pi) and pi-durable: one small loop, one tool, and a conversation that is an append-only log, so nothing is lost and work carries on where it stopped.

**The transcript.** Each photo's conversation is `conversation/transcript.jsonl`: one record per line, only ever appended, each flushed to storage before anything shows it (`Transcript`, an actor; one per photo). Records are the person's words (with the photo's context and pictures when they start a run), the model's responses exactly as they came, each script's report, failures, stops, resumes, summaries, and changes the person made by hand (a style, a restored version). The pictures the model was sent are files next to it, referred to by name. A last line cut off by the app closing is dropped on opening; nothing else is touched.

**Reading it.** `Conversation` works everything out from the records alone: the order the model saw them in, messages still waiting, why the latest run ended, and what comes next (`need`: nothing, an answer, or the scripts the model asked for). The thread on screen (`turns`) and the next request (`messages`) are both read from it, so what the person sees is what the model was told. Failed attempts are left out of requests; a script that never reported gets a report saying it did not run; a note never comes between a call and its report. Within a run every picture stays, so the model can compare every step; before it, only the latest set does, and the others are deleted from the phone once a run ends.

**The loop.** `Agent.run` reads the transcript, does the one thing it asks for next (ask the model, or run the script it asked for), writes down what happened, and goes round again. Because it starts from whatever the transcript says, the same loop carries out an instruction, picks up after Stop (Continue), and carries on after the app was closed mid-run: when the photo is opened again the work resumes by itself, and the model is told the script REPL started afresh. Work cut off three times in a row without progress waits for Continue instead.

**Failures.** A request that fails in a way that usually passes (a dropped connection, a busy or failing server, a rate limit) is sent again after 2, 4 and 8 seconds, and the thread says it is reconnecting. A bad key, no credit, or a request refused for good ends the run with the reason, and Continue picks it up.

**Talking while it works.** Words sent while the assistant works are written down at once as queued, and join the conversation between two steps, never between a script and its report. Leaving the photo does not stop the assistant: the photo stays open until it is done, and its thumbnail shows it is working.

**Long conversations.** When the previous request used nearly all of the model's context (from OpenRouter's model list), or the provider says a request is too long, older records are summarized by the same model into goal, preferences, what was done and what is open, and the summary takes their place in requests. Roughly the latest 20,000 tokens stay word for word. The thread keeps everything.

It depends on two small protocols, `ModelClient` and `AgentPort`. That is the seam for moving orchestration to a server later.

## Camera

`Camera` (app) asks AVFoundation for RAW only, one physical lens at a time, in one of two modes the person chooses (kept between launches). In zero processing (the default) it is `AVCapturePhotoSettings(rawPixelFormatType:)` with a Bayer format, no processed image, ProRAW off: Apple's photo processing (Smart HDR, Deep Fusion, night mode, multi-frame fusion, its noise reduction and sharpening) only runs on processed photos, so none of it touches the shot. Bayer RAW is the sensor's binned 12 MP readout, and each lens shoots at its own zoom. In ProRAW, Apple's processed RAW is asked for at the lens's largest size (48 MP where the sensor has it) and best quality. RAW capture requires the camera's own zoom to stay at 1, so zoom between lenses is Oscuru's: the viewfinder is magnified, the shot is the lens's whole frame, and the zoom becomes `PhotoDefaults.framing`, a centred crop kept in the photo's record that its settings start with, so it opens framed as shot and can still be zoomed out. Lenses are chosen by zoom: the longest one no closer than it.

The exposure is the photographer's. Aperture (where the lens has one to change: `Format.minLensAperture` below `maxLensAperture`), time and ISO are each the camera's until set by hand, and any mix is allowed: iOS 27's `setExposureModeCustom(lensAperture:duration:iso:)` takes a value or the "auto" constant for each, so setting only the time leaves ISO to the camera, and so on. `ExposureSettings` (core) is what is set; `CaptureService.apply` clamps it to the lens (`ExposureLimits`), asks the format whether it supports that mix, and where it does not holds the rest at their current values and reports them as set, so the screen never shows a value as automatic that is not. Compensation acts on whatever is left to the camera; with nothing left, the line shows the meter (`exposureTargetOffset`). A shot with anything set is asked for at speed prioritization, in ProRAW too: at any other, Apple's capture may use a time and an ISO of its own, and what is set must be what is shot. Focus is the camera's (tap to focus and meter) or a lens position held by hand, with the viewfinder magnified while it is turned. The dials stop at the thirds of a stop a camera names (`ExposureScale`, core, which also writes the values: "1/60", "0.5″", "ISO 640"); one dial view (`CameraDial`) serves zoom, aperture, time, ISO and focus, a stop of light always the same turn. A change of lens carries the exposure over as far as the new lens takes it and hands focus back to the camera.

The instruments read the live picture, not the photo: an `AVCaptureVideoDataOutput` beside the photo output (dropped if adding it would cost the lens its RAW formats) is measured a few times a second on a coarse grid (`FrameStatistics`, core) for a histogram and for a map of where a colour channel is blown, which the viewfinder draws as stripes over the picture. The live picture is Apple's video rendering of the sensor, so the stripes warn a little early (the RAW keeps somewhat more) and noise cannot be seen in it: the ISO is always on screen instead.

Frames is a feature turned on in Settings (off by default, `camera.frames`). With it on, zero processing has one more value in the line, ×1 until it is turned to ×2, ×4, ×8 or ×16, and beside its dial two choices that go with it: Bracket (±0 to ±3 stops) and Every (0 to 4 seconds between frames). A shot then takes that many Bayer frames at one focus, held for the burst (`CaptureService.captureBurst`), while the shutter's ring fills and the screen says to hold still. With no bracket they are all at the exposure the camera has, held too, back to back in as many as the camera takes in one request. With a bracket they go round three exposures (as set, that many stops less light, that many more: the time changes, and the ISO only where the time has reached the lens's limit). With an interval they are taken one at a time, that far apart. Each frame comes back with the time and ISO its file records and when it was taken.

`Camera.merge` then runs off the main thread. `DNG` (core) reads each frame's mosaic out of its DNG (the iPhone writes 64 tiles of lossless JPEG, decoded in parallel) and `FrameSet.make` (core) makes two things of them. One is the `FrameSet`: for each frame its exposure, the light it took as a share of the first frame's (measured from the frames, since what a camera says and what it did differ by a little), when it was taken, how sharp it is, how much of it is blown, and how it lies against the base. The other is the camera's own merge, which becomes the photo's file: built on the sharpest of the first three frames at the shot's own exposure, every frame merged into it, movement frozen. The file is the base frame's own DNG with the merged samples in place of its own (`DNG.replacingFrame`: one uncompressed strip, every other tag kept). The frames are kept beside it in the photo's folder (`frames/1.dng`, …, and `frames/set.json`), which is what lets them be merged another way later. If the frames cannot be merged, or the result cannot be opened, the first frame is kept as it was taken and the camera says so. ProRAW has no frames: it is already Apple's merging.

How kept frames are merged is a photo setting, `EditingState.frames` (a `FrameMerge`), so the assistant changes it like any other (`photo.current.frames`) and every version of the photo keeps its own. A way of merging names the base frame, the frames used, and what becomes of what moved between them. All of it is done on the mosaic, so the result is still a RAW picture, developed like any other:

- **freeze** (`BurstMerge`): the base's moment. Each other frame is lined up with the base by tiles of a half-size grey from a coarse copy down, a tile moving by whole grey pixels, that is by two photosites, so each sample stays behind its own colour filter. It is merged per tile and per colour in the frequency domain, after Hasinoff et al. (2016): what differs from the base by no more than the two frames' noise (each DNG's own `NoiseProfile`) is averaged, what differs by more keeps the base's own, so noise falls where the scene held still and nothing ghosts or blurs where it did not. `caution` moves that threshold.
- **blur**, **remove**, **trails** (`StackMerge`): each frame is lined up as a whole, by the camera's own movement between the frames (a fit to the tiles' moves that leaves out the tiles that disagree, `TileOffsets.camera`), so what moved in the scene stays where it was in each. Every photosite is then made from that photosite in all of them: their average (blur), what most of them agree on (remove: the average of those within noise of the middle value), or that with the brightest laid over it where it stands clear of the noise (trails).

A bracket needs nothing more than this. Every frame is brought to the base's brightness by the light it took, counts for as much as that light, and gives nothing where it is blown; where the base is blown, the picture is what a darker frame recorded there, provided that frame agrees the place is that bright (where it does not, something moved, and the base is kept). The merged file's white is as far above the base's as the darkest frame reaches, so those highlights are in the file, and the whole picture sits that many stops lower in it (`MergedFrame.brightening`), which the engine adds back to the exposure when it develops: the photo looks like its base frame, with highlights above white for the assistant to bring back and shadows as clean as the brightest frame made them. The samples are scaled by a power of two so the precision the merging earned is kept.

The engine makes a merge when a render first asks for it (`PhotoSession.rawSource`): the camera's own way is the photo's file, one frame alone is that frame's file, and any other way is merged then (a few seconds) and kept as `merges/<way>.dng` with what lining up found beside it, the five used last. Parts of the picture can be merged another way (`FrameMerge.areas`): each is developed like the rest and laid in through its mask before the local adjustments, so every kind of mask works there. `photo.current.frames.merge` makes the merge at once and returns what it found (how far the camera moved for each frame, and how much of each differs from the base), `photo.show("frame")` shows one frame alone, and `list()` gives the set. Settings shows how much room the kept frames take and lets go of them all (`Library.discardKeptFrames`): photos stay as they are merged, since merges already made are kept, and can no longer be merged another way.

The camera can be reached without opening the app first. `OscuruCameraIntent` (a `CameraCaptureIntent`, in `ios/Shared`, built into the app and both extensions as the system requires) is what the Camera Control, the Action button and the control in Control Center and on the Lock Screen (`OscuruControls`, a widget extension) run. On an unlocked iPhone the system opens the app and runs it there, and the app opens its camera (`CameraLaunch`). On a locked one it opens `OscuruCapture`, a Locked Camera Capture extension: it shows a live view (the system ends a capture extension without one) and asks to open the app, which after Face ID opens on its camera (`NSUserActivityTypeLockedCameraCapture`). Shots are not taken in the extension. The extensions have their own bundle IDs and App Store profiles, which `scripts/asc.py` registers and creates. Each shot goes into the library as a DNG through the same `Library.add` as an import, and is developed by the engine like any other RAW. The viewfinder is AVFoundation's ordinary preview, so it looks more finished than the shot. In UI tests the sample photo stands in for the lens.

## Styles

A style is a look with a name, to put on any photo: one type, `Style`, whose recipe is one of three things.

- **A look** (`Look`), saved from a photo edited in Oscuru, by the person (the Styles button beside the composer) or the assistant (`photo.styles.save`): tone, colour, curves, HSL, grading, grain and halation. Crop, detail and local adjustments stay with the photo they were made on. White balance is kept as a shift from the as-shot value, so a warm style stays warm on a photo taken in different light.
- **A fit** (`LookFit`), learned on the home screen from an original and its edit. `LookFitting.fit` compares them point by point on small Display P3 bitmaps (the original developed Oscuru's neutral way when it is RAW) and takes, per channel, the median of what each value became as a curve, then searches the saturation that brings the rest closest. The app shows the original with the fit beside the edit, and how close it came.
- **A match** (`StyleFingerprint`), learned from one picture: each channel's quantiles and the colourfulness. Every time it is applied the photo is measured and its channels' quantiles are mapped onto the fingerprint's.

A fit and a match replace only tone and colour, and keep the photo's own exposure and white balance. `Style.applied` is the one place a style becomes settings; `PhotoRenderer.apply` gives it the photo to measure. A style goes on the open photo from the strip above the composer (each tile shows it tried on the photo), on many photos from the home screen (tap the style, then the photos; each is changed through its own editor, as a step in its own conversation), and by the assistant through `photo.styles`. `StyleStore` keeps the styles on disk with the small picture that stands for each.

## Prompts

Above the composer of a photo that has no instruction yet are the person's prompts: instructions kept to send with a tap (`PromptStore`, kept in the app's defaults). A `SavedPrompt` is its words and, if the person gives it one, a short title: the button shows the title (or else the words) and a tap sends the words. They start as four ideas in the app's language; the first button of the row opens `PromptsView`, the one place they are changed: a tap opens one to write its title and words, a swipe deletes it, Edit puts them in another order, and Add a Prompt starts a new one.

## Pictures and sharing

`PhotoRenderer` is one photo open in the engine: every picture of it the app shows, saves or sends comes from there, and it is what scripts see of the app. An open photo's editor has one; `PhotoRenderer.with` opens one for as long as a piece of work needs it, for photos no editor has open. `AppModel.export` is the one way photos leave the app, from the photo screen and from a selection in the library alike (`ShareButton`): developed at full size as JPEGs, or the original files untouched, so a RAW stays RAW. `SaveButton` puts the developed JPEGs straight into the person's photo library (`AppModel.saveToPhotos`, add-only access), with their capture details, so Photos files them under when they were taken.

## Collages and splitting

Both make new photos from ones in the library; each is then a photo like any other, with its own conversation.

A collage is made by choosing photos and tapping Combine. `AppModel.combine` develops them as `export` does and `Library.addCollage` keeps those JPEGs as the collage's pieces, beside a `CollageManifest` that is its original file. How the pieces sit (canvas shape, gap, its colour, one cell per piece with a focus and zoom) is `EditingState.layout`, so the assistant changes it with `photo.current.layout.set` and every version keeps its own; it starts as `CollageLayout.automatic`. The engine opens the manifest like a photo and draws the canvas in `Effects.collage` (each piece scaled with a Lanczos filter to cover its cell), then develops it like any other picture. Later edits to the photos it was made from do not reach it.

`photo.split` asks for new photos made of parts of this one. The script only records them (`ScriptOutcome.parts`): each is these settings with the crop narrowed to its part and local adjustments moved with it (`EditingState.part`). When the script has ended without an error, the editor makes them with `Library.duplicate`, which copies the original; on the phone's disk a copy is a clone, so it takes no space.

## Accounts and cost

There is no Oscuru server. The person signs in to OpenRouter (OAuth PKCE) or pastes a key; the key lives in the keychain. Every response carries what it cost; `UsageLedger` records it per user, instruction and photo, and Settings shows today, this month and in total. Oscuru never limits spending; a cap, if wanted, is set on the key at openrouter.ai.

## Storage

Each photo has a folder in the app's documents: the copied original, `doc.json` (what the engine reported, and a copy of the photo's settings now), a thumbnail, and `conversation/` (the transcript and the pictures the model was last sent). A thread saved by an earlier version (`thread.json`) is read once into the transcript. Styles, settings and the usage record are JSON files next to them.

## Tests

- `OscuruCoreTests` (Linux and macOS): state, colour pipeline, statistics, styles, the agent loop with a played-back model (retries, stop and Continue, resuming after the app closed, messages sent while it works, summaries, a cut-off last line), the OpenRouter client, and that `docs/photo-api.d.ts` is current.
- `OscuruEngineTests` (macOS): what the TypeScript-era port assumes about Core Image — table layouts, colour spaces, rotation and white-balance directions, regions, exports, and that RAW files go through the RAW decoder.
- `OscuruScriptingTests` (macOS): the JavaScriptCore environment — the API, the REPL, `photo.show`, styles, errors, cancellation, abandoned loops.
- `OscuruUITests` (simulator, English and Italian): the whole flow against a sample photo and a played-back model.
