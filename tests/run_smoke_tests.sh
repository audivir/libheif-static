#!/usr/bin/env bash
#
# Exercises the static libheif.a built by build.sh:
# - smoke_test decodes real HEIC/AVIF files (HEVC/AV1 decode, alpha, clean-aperture cropping).
# - codec_test encodes with x265 and aom, decodes AV1 via both dav1d and aom explicitly, and
#   exercises the libsharpyuv chroma-downsampling path.
#
# Usage: ./tests/run_smoke_tests.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
LIBHEIF_DIR="$ROOT_DIR/vendor/libheif"
BUILD_DIR="$ROOT_DIR/build/tests"

mkdir -p "$BUILD_DIR"

echo "==> Building test binaries"
CC="${CC:-cc}"
PLATFORM_LIBS=(-lstdc++)
if [[ "$(uname -s)" == "Darwin" ]]; then
  PLATFORM_LIBS=(-lc++ -framework CoreFoundation -framework VideoToolbox)
fi
LIBHEIF_LIBS=(-lheif -lde265 -lx265 -laom -ldav1d -lsharpyuv)

"$CC" "$ROOT_DIR/tests/smoke_test.c" \
  -I "$DIST_DIR/include" -L "$DIST_DIR/lib" \
  "${LIBHEIF_LIBS[@]}" "${PLATFORM_LIBS[@]}" \
  -o "$BUILD_DIR/smoke_test"

"$CC" "$ROOT_DIR/tests/codec_test.c" \
  -I "$DIST_DIR/include" -L "$DIST_DIR/lib" \
  "${LIBHEIF_LIBS[@]}" "${PLATFORM_LIBS[@]}" \
  -o "$BUILD_DIR/codec_test"

FAIL=0

run_case() {
  local file="$1"
  local expect_alpha="$2"
  if ! "$BUILD_DIR/smoke_test" "$file" "$expect_alpha"; then
    FAIL=1
  fi
}

run_case "$LIBHEIF_DIR/examples/example.heic" 0
run_case "$LIBHEIF_DIR/examples/example.avif" 0
run_case "$LIBHEIF_DIR/tests/data/with-alpha-512x512.heic" 1
run_case "$LIBHEIF_DIR/tests/data/simple_osm_tile_alpha.avif" 1
run_case "$LIBHEIF_DIR/tests/data/clap_cropped.avif" 0
run_case "$LIBHEIF_DIR/tests/data/conformance_window_padding.heic" 0

if ! "$BUILD_DIR/codec_test" "$BUILD_DIR"; then
  FAIL=1
fi

exit "$FAIL"
