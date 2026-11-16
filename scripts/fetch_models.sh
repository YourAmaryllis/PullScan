#!/bin/sh
# Downloads the model files that are too large for git from the GitHub release.
#   scripts/fetch_models.sh          # phone models -> android/models/src/main/assets/ (needed to build the app)
#   scripts/fetch_models.sh --ios    # Core ML model -> ios/PullScan/Model/ (needed to build the iPhone app)
#   scripts/fetch_models.sh --all    # also the PyTorch checkpoint, fp32 index and Core ML model -> embeddings/
set -eu
TAG="${PULLSCAN_RELEASE:-v1.0}"
BASE="https://github.com/YourAmaryllis/PullScan/releases/download/$TAG"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/android/models/src/main/assets"
EMB="$ROOT/embeddings/dinov2-s14-224x308-ft"

get() {  # get <file> <dir>
    mkdir -p "$2"
    echo "$1 -> $2"
    curl -fL --retry 3 -o "$2/$1.part" "$BASE/$1" && mv "$2/$1.part" "$2/$1"
}


if [ "${1:-}" = "--ios" ]; then
    IOS="$ROOT/ios/PullScan/Model"
    get Embedder.mlpackage.zip "$IOS"
    (cd "$IOS" && rm -rf Embedder.mlpackage && unzip -q Embedder.mlpackage.zip && rm Embedder.mlpackage.zip)
    exit 0
fi
get embedder.int8.onnx "$ASSETS"
get embedder.onnx "$ASSETS"
if [ "${1:-}" = "--all" ]; then
    for f in embedder.onnx embedder.int8.onnx backbone.pt embeddings.f32.npy Embedder.mlpackage.zip; do
        get "$f" "$EMB"
    done
    (cd "$EMB" && rm -rf Embedder.mlpackage && unzip -q Embedder.mlpackage.zip && rm Embedder.mlpackage.zip)
fi
