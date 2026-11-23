#!/usr/bin/env bash
# Makes sure this checkout knows its Expo (EAS) project before `eas build` or `eas update`.
#
# The project id normally lives in app.json (extra.eas.projectId), or comes from the EAS_PROJECT_ID
# environment variable. When neither is there, this asks Expo for the project named after the app's
# slug under the token's account, creating it the first time, and writes the id into app.json for
# the rest of the job. Commit that id (it is not a secret) to skip this step.
set -euo pipefail
cd "$(dirname "$0")/.."

id_in_app_json() {
  node -e 'const id = require("./app.json").expo?.extra?.eas?.projectId; if (id) console.log(id);'
}

if [ -n "${EAS_PROJECT_ID:-}" ]; then
  echo "Using the Expo project from EAS_PROJECT_ID."
  exit 0
fi
if [ -n "$(id_in_app_json)" ]; then
  echo "Using the Expo project in app.json."
  exit 0
fi

# `eas init` cannot write into a dynamic config, so let it see only app.json for a moment.
mv app.config.ts app.config.ts.linking
trap 'mv app.config.ts.linking app.config.ts' EXIT
eas init --force --non-interactive

PROJECT_ID="$(id_in_app_json)"
if [ -z "$PROJECT_ID" ]; then
  echo "eas init did not write a project id into app.json." >&2
  exit 1
fi
echo "Linked Expo project $PROJECT_ID."
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "EAS_PROJECT_ID=$PROJECT_ID" >> "$GITHUB_ENV"
  echo "::notice::Expo project id: $PROJECT_ID. Add it to app.json as expo.extra.eas.projectId (or as the repository variable EAS_PROJECT_ID) so installed builds and updates always agree."
fi
