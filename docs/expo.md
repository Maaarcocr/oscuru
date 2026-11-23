# Building and publishing with Expo

Oscuru has native code (the rendering engine), so it cannot run in Expo Go. It needs its own build, made on Expo's servers (EAS Build). After that, changes to the JavaScript side reach installed builds over the air (EAS Update) within a minute or two, without a new build.

Nothing here has been run against a real Expo or Apple account yet: the workflows were written from Expo's documentation and need the one-time setup below.

## What runs where

| File | Purpose |
| --- | --- |
| `.github/workflows/ci.yml` | On every push and PR: types, lint, unit tests and the iOS bundle (Linux); the engine's tests (macOS); an unsigned build for the simulator that is launched and runs the on-device self-test |
| `.github/workflows/expo-build.yml` | **Manual.** Starts an EAS build and, for production builds, sends it to TestFlight |
| `.github/workflows/expo-update.yml` | On every push to `main`, and manually: publishes an over-the-air update |
| `eas.json` | Build profiles: `production` (TestFlight/App Store), `development` (development client), `simulator` |
| `app.json`, `app.config.ts` | App configuration. Updates switch on once the Expo project is linked |
| `tools/link-eas-project.sh` | Finds or creates the Expo project for this app when its id is not in `app.json` yet |

## One-time setup

1. **Expo account and token.** Create an account at expo.dev, then an access token (Account settings → Access tokens). Add it to this repository as the secret `EXPO_TOKEN`.

2. **Apple side.** The bundle id is `com.rudilosso.oscuru` (change it in `app.json` if you want another). In App Store Connect, create the app for that bundle id and note its numeric Apple ID.

3. **Signing.** Choose one:

   - **Let Expo keep the credentials.** On any computer with Node: `npx eas-cli@latest login`, then `npx eas-cli@latest credentials --platform ios` in a checkout of this repository, and sign in with your Apple ID when asked. Expo creates and stores the distribution certificate and provisioning profile. After that, builds from GitHub need nothing from Apple.
   - **Supply them yourself**, as Putia does. Create an App Store provisioning profile for the bundle id with your Apple Distribution certificate, and add the secrets `APPLE_DISTRIBUTION_P12_BASE64`, `APPLE_DISTRIBUTION_P12_PASSWORD` and `APPLE_APP_STORE_PROFILE_BASE64`. The certificate and its password can be the ones Putia uses; the profile is specific to Oscuru. When these secrets exist, the build workflow signs with them.

4. **TestFlight.** Add the secrets `ASC_PRIVATE_KEY_BASE64`, `ASC_KEY_ID` and `ASC_ISSUER_ID` (the App Store Connect API key; Putia's team key works) and the repository variable `ASC_APP_ID` (the numeric Apple ID from step 2).

5. **Project id.** The first workflow run links the Expo project and prints its id in a notice. Add it to `app.json` as `expo.extra.eas.projectId` and commit, so every build and update agrees on the project.

## Getting a build on your phone

**Actions → Expo build → Run workflow**, profile `production`, submit on. The build runs on Expo's servers (follow it on expo.dev); when it finishes it is uploaded to App Store Connect and appears in TestFlight after Apple's processing. Build numbers are kept by Expo and increase by themselves.

A `development` build is a development client for devices registered with `eas device:create`; use it with `npx expo start` when working on the app interactively.

## Shipping changes without a build

Merging to `main` publishes an update to the `production` channel. Installed builds download it at the next start and use it from the start after that.

An update only reaches builds whose native side matches: the runtime version is a fingerprint of the native project (`runtimeVersion.policy: "fingerprint"`). A change to the Swift module, to native dependencies or to `app.json` changes the fingerprint, and then a new build is needed. Changes to screens, the agent, the prompt, the scripting API or the colour pipeline are JavaScript and go over the air.

## OpenRouter sign-in

The app opens `https://openrouter.ai/auth` with a PKCE challenge and `oscuru://openrouter` as the callback. OpenRouter's documentation describes https and localhost callbacks and does not say whether a custom scheme is accepted. If the page does not return to the app, use "Get a code instead" in Settings: OpenRouter shows a code to paste. A pasted API key always works.

## Verification boundary

CI proves that the app compiles for iOS, starts in the simulator, and that the sandbox, the bridge and the engine work together there on a synthetic photo. It does not prove anything about signing, Expo's build service, TestFlight, the system photo picker, real RAW files from your camera, or how the edits look on a phone. Only a build on a device shows those.
