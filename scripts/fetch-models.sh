#!/usr/bin/env bash
# Fetches the on-device models the assistant's masks use, in Apple's Core ML conversions on Hugging
# Face (Apache-2.0), each pinned to one revision and checked against known checksums. They only find
# what is in a photo; they never generate pixels.
#   - Segment Anything 2.1 tiny (apple/coreml-sam2.1-tiny, about 77 MB): selects an object by tapping it.
#   - Depth Anything V2 small, 8-bit (apple/coreml-depth-anything-v2-small, about 25 MB): how far each
#     part of a photo is, for depth ranges.
#
# The packages go to ios/ModelSources. On macOS they are also compiled into ios/Models, which the app
# bundles. Both folders are ignored by git. Safe to run again: files that are already there and
# correct are kept.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/ios/ModelSources"
COMPILED="$ROOT/ios/Models"

SEGMENTATION=(
  "dd72aa75e3f2f92d0653696bf4d8350d87690d92b116b34912fe640f2b116e08 SAM2_1TinyImageEncoderFLOAT16.mlpackage/Manifest.json"
  "6cbc50301ee3ff4a9366083f9647e1f06762759542d8dd0fac394ebc3682cce7 SAM2_1TinyImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel"
  "eab96eb8ff35720c79eedc0cac2a4ef32d685f9c994c39736027078528c48a97 SAM2_1TinyImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
  "0c0f9b80f0445017dac52f81e93aeb50b9c2c9918708c882df4a65671fda2bd4 SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Manifest.json"
  "3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3 SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel"
  "af466cf28ef8838f409c2bfd8cc0049b9efbf9db335d60a57dbfc5160af883f2 SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
  "dc6121b61ac560498080d55f9d5fb293cdb305f942a85adb5b71dc8e9d14a8aa SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Manifest.json"
  "4601f302d4c6936e15de3a22089c2afe1fa009ef703f82147ff829b4be677577 SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel"
  "f5a8635981199fa1199007ed6798c61a326288548b74553b3c2ddb932fcdc8de SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
)
DEPTH=(
  "5530317f2a7c4318b34efd9855694480a78122d8be89e703278b0f7b9337dbdc DepthAnythingV2SmallF16P8.mlpackage/Manifest.json"
  "da3f4c6a8be93a439b1bc56ba57074c09f270b3d28052d798bc106d1259e5a1d DepthAnythingV2SmallF16P8.mlpackage/Data/com.apple.CoreML/model.mlmodel"
  "660a57cf7becfeac080a9bb02a263be59fd57b5c4d17ff8912833bc8b6edae04 DepthAnythingV2SmallF16P8.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
)

checksum() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() {
  local repository="$1" revision="$2"
  shift 2
  for entry in "$@"; do
    expected="${entry%% *}"
    path="${entry#* }"
    target="$SOURCES/$path"
    if [[ -f "$target" && "$(checksum "$target")" == "$expected" ]]; then continue; fi
    mkdir -p "$(dirname "$target")"
    for attempt in 1 2 3 4; do
      if curl -fsSL --retry 2 -o "$target.part" "https://huggingface.co/$repository/resolve/$revision/$path"; then break; fi
      [[ $attempt == 4 ]] && { echo "Could not download $path" >&2; exit 1; }
      sleep $((attempt * 2))
    done
    actual="$(checksum "$target.part")"
    if [[ "$actual" != "$expected" ]]; then
      rm -f "$target.part"
      echo "Checksum mismatch for $path: expected $expected, got $actual" >&2
      exit 1
    fi
    mv "$target.part" "$target"
  done
}

fetch "apple/coreml-sam2.1-tiny" "39ae0a8a83e5e6cd196e804bf7cccc5f8171f306" "${SEGMENTATION[@]}"
fetch "apple/coreml-depth-anything-v2-small" "cfef6f6f2a70783dedc0bfae40cecbc2052285d3" "${DEPTH[@]}"
echo "Model sources: $SOURCES"

if [[ "$(uname -s)" == "Darwin" ]]; then
  mkdir -p "$COMPILED"
  for package in "$SOURCES"/*.mlpackage; do
    name="$(basename "$package" .mlpackage)"
    # Compiled once per checksum of its weights, so a changed model is compiled again.
    stamp="$COMPILED/$name.mlmodelc/.source"
    weights="$(checksum "$package/Data/com.apple.CoreML/weights/weight.bin")"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$weights" ]]; then continue; fi
    rm -rf "$COMPILED/$name.mlmodelc"
    xcrun coremlcompiler compile "$package" "$COMPILED" >/dev/null
    echo "$weights" > "$stamp"
  done
  echo "Compiled models: $COMPILED"
fi
