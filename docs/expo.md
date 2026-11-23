# Building and publishing

Oscuru is a native Swift app. CI builds and tests it on GitHub's Mac runners on every push.

## How builds reach TestFlight today

`scripts/testflight.sh` signs, archives and uploads the app, and `scripts/asc.py` handles App Store Connect: it finds the bundle ID, app record and provisioning profile, picks the next build number, and keeps an internal TestFlight group "Me" that gets every build. Oscuru has no signing secrets of its own yet, so for now these scripts run from a temporary workflow in the putia-app repository, `.github/workflows/oscuru-testflight.yml` on the `claude/youthful-gates-jldvp7` branch, which uses that team's Apple credentials (the owner approved this on 2026-11-23). To ship a build, write the full Oscuru commit hash to `.github/oscuru-build-request` in putia-app and push.

The team's API key does not have the Admin role, so it cannot register identifiers or create profiles. These were made by hand once: the App ID `com.rudilosso.oscuru`, the profile "Oscuru App Store", and the App Store Connect app (Apple ID 6838299074). If the distribution certificate is renewed, create a new profile for it by hand as well.

To make Oscuru independent of putia-app, add the same secrets to this repository (`APPLE_DISTRIBUTION_P12_BASE64`, `APPLE_DISTRIBUTION_P12_PASSWORD`, `ASC_PRIVATE_KEY_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID`) and the variable `TEAM_ID`, run `scripts/testflight.sh` from a workflow here, and delete the one in putia-app.

## The Expo route (not used yet)

Expo's build service (EAS Build) is set up as an alternative:

## What runs where

| File | Purpose |
| --- | --- |
| `.github/workflows/ci.yml` | Every push: string check; core tests on Linux; engine and scripting tests on macOS; an unsigned Release build for a device; UI tests on a simulator in English and Italian, with screenshots kept as an artifact |
| `.github/workflows/expo-build.yml` | **Manual.** Generates the Xcode project, starts an EAS build and, when asked, sends it to TestFlight |
| `eas.json`, `.eas/build/native-ios.yml` | The build profile, and the build steps: sign, archive with fastlane, upload. No npm install or CocoaPods, which only React Native apps need |
| `app.json`, `package.json` | Only so EAS recognizes the project; the app does not use them |
| `.easignore` | What is uploaded to Expo: the repository plus the generated Xcode project |

## One-time setup

1. **Expo account and token.** Create an account at expo.dev and an access token (Account settings → Access tokens). Add it to this repository as the secret `EXPO_TOKEN`.
2. **App Store Connect.** Create the app for the bundle id `com.rudilosso.oscuru` (team `2R27Z5A8V6`, as Putia) and note its numeric Apple ID.
3. **Signing.** Once, on any computer with Node and a checkout of this repository: `(cd ios && xcodegen generate)` on a Mac, or skip that step elsewhere; then `npx eas-cli@latest login` and `npx eas-cli@latest credentials --platform ios`, signing in with the Apple ID when asked. Expo creates and keeps the distribution certificate and provisioning profile. After that, builds need nothing from Apple.
4. **TestFlight.** Add the secrets `ASC_PRIVATE_KEY_BASE64`, `ASC_KEY_ID` and `ASC_ISSUER_ID` (the team's App Store Connect API key, as Putia uses) and the repository variable `ASC_APP_ID` (the Apple ID from step 2).
5. **Project id.** The first run links the Expo project and prints its id. Add it to `app.json` as `expo.extra.eas.projectId` and commit.

## Getting a build on your phone

**Actions → Expo build → Run workflow.** The build runs on Expo's servers (follow it on expo.dev). With "submit" on, it goes to App Store Connect and appears in TestFlight after Apple's processing. Build numbers are kept by Expo and increase by themselves.

Over-the-air updates (EAS Update) only apply to JavaScript apps, so every change to Oscuru needs a new build.

## OpenRouter sign-in

The app opens `https://openrouter.ai/auth` with a PKCE challenge and `oscuru://openrouter` as the callback. OpenRouter's documentation describes https and localhost callbacks and does not say whether a custom scheme is accepted. If the page does not come back to the app, use "Get a code instead" in Settings: OpenRouter shows a code to paste. A pasted API key always works.

## Verification boundary

CI proves the app compiles for a device and that the flow works on a simulator against a played-back model and a sample photo. Expo's documentation says its build service works for native projects, but does not walk through one without React Native: the custom build in `.eas/build/native-ios.yml` uses only its documented steps, and has not been run against a real Expo or Apple account yet. Nothing here has been tested with a real OpenRouter key, the system photo picker, real RAW files from a camera, or how the edits look on a phone. Only a TestFlight build shows those.
