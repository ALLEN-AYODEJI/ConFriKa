#!/usr/bin/env bash
# Download the MediaPipe Tasks Vision runtime + hand-landmark model into vendor/.
# These binaries are NOT committed (see .gitignore); run this once after cloning
# so the extension can load everything locally (MV3 forbids remote scripts).
set -euo pipefail

VER="0.10.18"
BASE="https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${VER}"
MODEL="https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task"

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
mkdir -p vendor/wasm

echo "→ vision_bundle.mjs"
curl -fL "$BASE/vision_bundle.mjs" -o vendor/vision_bundle.mjs

for f in vision_wasm_internal.js vision_wasm_internal.wasm \
         vision_wasm_nosimd_internal.js vision_wasm_nosimd_internal.wasm; do
  echo "→ wasm/$f"
  curl -fL "$BASE/wasm/$f" -o "vendor/wasm/$f"
done

echo "→ hand_landmarker.task (model)"
curl -fL "$MODEL" -o vendor/hand_landmarker.task

echo "✅ Vendor assets ready in $DIR/vendor"
