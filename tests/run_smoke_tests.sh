#!/usr/bin/env bash
#
# Decodes a handful of real HEIC/AVIF files through the static libheif.a built
# by build.sh, covering HEVC, AV1, alpha channel, and clean-aperture cropping.
#
# Usage: ./tests/run_smoke_tests.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
LIBHEIF_DIR="$ROOT_DIR/vendor/libheif"
BIN="$ROOT_DIR/build/tests/smoke_test"

mkdir -p "$(dirname "$BIN")"

echo "==> Building smoke test binary"
CC="${CC:-cc}"
PLATFORM_LIBS=(-lstdc++)
if [[ "$(uname -s)" == "Darwin" ]]; then
  PLATFORM_LIBS=(-lc++ -framework CoreFoundation -framework VideoToolbox)
fi
"$CC" "$ROOT_DIR/tests/smoke_test.c" \
  -I "$DIST_DIR/include" -L "$DIST_DIR/lib" \
  -lheif -lde265 -lx265 -laom -ldav1d -lsharpyuv \
  "${PLATFORM_LIBS[@]}" \
  -o "$BIN"

FAIL=0

run_case() {
  local file="$1"
  local expect_alpha="$2"
  if ! "$BIN" "$file" "$expect_alpha"; then
    FAIL=1
  fi
}

run_case "$LIBHEIF_DIR/examples/example.heic" 0
run_case "$LIBHEIF_DIR/examples/example.avif" 0
run_case "$LIBHEIF_DIR/tests/data/with-alpha-512x512.heic" 1
run_case "$LIBHEIF_DIR/tests/data/simple_osm_tile_alpha.avif" 1
run_case "$LIBHEIF_DIR/tests/data/clap_cropped.avif" 0
run_case "$LIBHEIF_DIR/tests/data/conformance_window_padding.heic" 0

exit "$FAIL"
