#!/usr/bin/env bash
# record-app-preview.sh — riddim-release template — copy to scripts/marketing/ and adjust
#
# Records an App Preview video by running an XCUITest against a simulator and
# post-processing the capture to App Store-ready specs (886×1920, 30fps, ≤30s,
# silent AAC audio track).
#
# Required ENV:
#   SCHEME           — Xcode scheme name (e.g. JustPlayIt)
#   BUNDLE_ID        — app bundle identifier (e.g. com.riddimsoftware.justplayit)
#   UITEST_TARGET    — xcodebuild -only-testing path
#                      (e.g. JustPlayItUITests/AppPreviewRecordingTests/testAppPreviewSequence)
#   PRIMARY_LOCALE   — locale for the fastlane app-previews dir (e.g. en-US)
#
# Optional ENV:
#   DEVICE_NAME      — simulator name (default: iPhone 17 Pro Max)
#   XCODE_DESTINATION — xcodebuild destination string (default: resolved simulator UDID for DEVICE_NAME)
#   XCODEPROJ_PATH   — path to the .xcodeproj file (default: $SCHEME.xcodeproj)
#   IOS_WORKDIR      — directory containing the Xcode project (default: ios)
#   OUTPUT_DIR       — directory for the output mp4 (default: docs/marketing/preview)
#
# Dependencies:
#   - ffprobe/ffmpeg (brew install ffmpeg)
#   - xcrun simctl (Xcode command-line tools)
#   - xcodebuild (Xcode)
#   - scripts/evidence/run-evidence.sh in the consuming repo (used for post-processing
#     if present; ffmpeg inline fallback used otherwise)

set -euo pipefail

SCHEME="${SCHEME:?Set SCHEME}"
BUNDLE_ID="${BUNDLE_ID:?Set BUNDLE_ID}"
UITEST_TARGET="${UITEST_TARGET:?Set UITEST_TARGET}"
PRIMARY_LOCALE="${PRIMARY_LOCALE:?Set PRIMARY_LOCALE}"
DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro Max}"
IOS_WORKDIR="${IOS_WORKDIR:-ios}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-docs/marketing/preview}"

resolve_from_root() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$REPO_ROOT" "$1" ;;
  esac
}

IOS_DIR="$(resolve_from_root "$IOS_WORKDIR")"
OUTPUT_DIR="$(resolve_from_root "$OUTPUT_DIR")"
FINAL_VIDEO="$OUTPUT_DIR/app-preview-final.mp4"
FASTLANE_PREVIEW_DIR="$IOS_DIR/fastlane/app-previews/$PRIMARY_LOCALE"
FASTLANE_PREVIEW_VIDEO="$FASTLANE_PREVIEW_DIR/IPHONE_67_app-preview.mp4"

XCODEPROJ_PATH="${XCODEPROJ_PATH:-$SCHEME.xcodeproj}"

EVIDENCE="$REPO_ROOT/scripts/evidence/run-evidence.sh"

mkdir -p "$OUTPUT_DIR"

for tool in ffmpeg ffprobe; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required (brew install ffmpeg)" >&2
    exit 1
  fi
done

DEVICE_UDID=$(DEVICE_NAME="$DEVICE_NAME" python3 - <<'PYEOF'
import json
import os
import subprocess
import sys

name = os.environ["DEVICE_NAME"]
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtime_devices in devices.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("name") == name and device.get("isAvailable", True):
            print(device["udid"])
            sys.exit(0)
print(f"error: no available simulator named {name!r}", file=sys.stderr)
sys.exit(1)
PYEOF
)

XCODE_DESTINATION="${XCODE_DESTINATION:-platform=iOS Simulator,id=$DEVICE_UDID}"

RAW_STEM="$(mktemp "$OUTPUT_DIR/raw-capture.XXXXXX")"
RAW_VIDEO="$RAW_STEM.mp4"
rm -f "$RAW_STEM"

cleanup_raw_video() {
  rm -f "$RAW_VIDEO"
}
trap cleanup_raw_video EXIT

if [[ ! -d "$IOS_DIR" ]]; then
  echo "error: IOS_WORKDIR does not exist: $IOS_DIR" >&2
  exit 1
fi

xcrun simctl shutdown "$DEVICE_UDID" >/dev/null 2>&1 || true
xcrun simctl erase "$DEVICE_UDID" >/dev/null
xcrun simctl boot "$DEVICE_UDID" >/dev/null
xcrun simctl bootstatus "$DEVICE_UDID" -b >/dev/null
xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

rm -f "$FINAL_VIDEO"

xcrun simctl io "$DEVICE_UDID" recordVideo --codec h264 "$RAW_VIDEO" &
RECORDER_PID=$!

stop_recording() {
  if kill -0 "$RECORDER_PID" >/dev/null 2>&1; then
    kill -INT "$RECORDER_PID" >/dev/null 2>&1 || true
    wait "$RECORDER_PID" >/dev/null 2>&1 || true
  fi
}
trap 'stop_recording; cleanup_raw_video' EXIT

cd "$IOS_DIR"
xcodebuild test \
  -project "$XCODEPROJ_PATH" \
  -scheme "$SCHEME" \
  -destination "$XCODE_DESTINATION" \
  -only-testing:"$UITEST_TARGET"

stop_recording
trap cleanup_raw_video EXIT

# Post-process: trim to ≤30s, resize to 886×1920, encode H.264.
# Delegate to scripts/evidence/run-evidence.sh if available in the consuming
# repo; otherwise inline the ffmpeg commands directly.
if [[ -x "$EVIDENCE" ]]; then
  "$EVIDENCE" record-preview --input "$RAW_VIDEO" --output "$FINAL_VIDEO" \
    --duration 30 --width 886 --height 1920 --fps 30
else
  # Inline fallback: trim, scale, and encode using ffmpeg directly.
  ffmpeg -y -i "$RAW_VIDEO" \
    -t 30 \
    -vf "scale=886:1920:force_original_aspect_ratio=decrease,pad=886:1920:(ow-iw)/2:(oh-ih)/2" \
    -r 30 \
    -c:v libx264 -crf 18 -preset slow \
    -an \
    "$FINAL_VIDEO"
fi

# Apple's App Preview pipeline rejects videos with no audio track, so mux in
# a silent AAC stereo track at 44.1 kHz.
TMP_WITH_AUDIO="${FINAL_VIDEO%.mp4}.with-audio.mp4"
ffmpeg -y -i "$FINAL_VIDEO" -f lavfi -i anullsrc=cl=stereo:r=44100 \
  -shortest -map 0:v -map 1:a -c:v copy -c:a aac -b:a 128k "$TMP_WITH_AUDIO"
mv "$TMP_WITH_AUDIO" "$FINAL_VIDEO"

ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,r_frame_rate \
  -show_entries format=duration \
  -of default=noprint_wrappers=1 "$FINAL_VIDEO"
echo "Wrote $FINAL_VIDEO"

mkdir -p "$FASTLANE_PREVIEW_DIR"
cp "$FINAL_VIDEO" "$FASTLANE_PREVIEW_VIDEO"
echo "Wrote $FASTLANE_PREVIEW_VIDEO"
