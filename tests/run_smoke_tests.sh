#!/usr/bin/env bash
#
# Exercises the static libheif.a built by build.sh: pkg-config resolution of
# libheif and its Requires.private deps, smoke_test decoding real HEIC/AVIF
# files, and codec_test encoding with x265/aom and decoding AV1 via both
# dav1d and aom, exercising the libsharpyuv path.
#
# Usage: ./tests/run_smoke_tests.sh [--target native|windows-amd64|windows-arm64] [--no-build]
#
# A windows-* target built on a non-matching host is compiled but not run.
# --no-build skips compiling and runs pre-built binaries already at
# build<target-suffix>/tests/ (e.g. downloaded from another CI runner, since
# the .exe is fully static and needs no toolchain to execute).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBHEIF_DIR="$ROOT_DIR/vendor/libheif"
TARGET="native"
NO_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --no-build) NO_BUILD=1; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

HOST_IS_WINDOWS=0
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) HOST_IS_WINDOWS=1 ;;
esac

if [[ "$TARGET" == "native" && "$HOST_IS_WINDOWS" -eq 1 ]]; then
  case "$(uname -m)" in
    aarch64|arm64) TARGET="windows-arm64" ;;
    *) TARGET="windows-amd64" ;;
  esac
fi

case "$TARGET" in
  native) TARGET_SUFFIX="" ;;
  windows-amd64) TARGET_SUFFIX="-windows-amd64"; MINGW_TRIPLE="x86_64-w64-mingw32"; TARGET_ARCH="x86_64" ;;
  windows-arm64) TARGET_SUFFIX="-windows-arm64"; MINGW_TRIPLE="aarch64-w64-mingw32"; TARGET_ARCH="aarch64" ;;
  *) echo "Unknown --target: $TARGET (expected native, windows-amd64, or windows-arm64)" >&2; exit 1 ;;
esac

DIST_DIR="$ROOT_DIR/dist$TARGET_SUFFIX"
BUILD_DIR="$ROOT_DIR/build$TARGET_SUFFIX/tests"
EXE_SUFFIX=""
DEFINES=()
EXTRA_LIBS=()
LINK_FLAGS=()
CAN_RUN=1

mkdir -p "$BUILD_DIR"

echo "==> Verifying pkg-config resolution"
if ! PKG_CONFIG_PATH="$DIST_DIR/lib/pkgconfig" PKG_CONFIG_LIBDIR="$DIST_DIR/lib/pkgconfig" \
    pkg-config --print-errors --cflags --libs --static libheif; then
  echo "ERROR: pkg-config failed to resolve libheif and its Requires.private deps." >&2
  exit 1
fi

if [[ "$TARGET" == windows-* ]]; then
  EXE_SUFFIX=".exe"
  case "$(uname -m)" in
    x86_64|amd64) HOST_ARCH="x86_64" ;;
    aarch64|arm64) HOST_ARCH="aarch64" ;;
    *) HOST_ARCH="unknown" ;;
  esac
  if [[ "$HOST_IS_WINDOWS" -ne 1 || "$HOST_ARCH" != "$TARGET_ARCH" ]]; then
    CAN_RUN=0
  fi
fi

if [[ "$NO_BUILD" -eq 0 ]]; then
  echo "==> Building test binaries"
  if [[ "$TARGET" == windows-* ]]; then
    HOST_EXE_EXT=""
    if [[ "$HOST_IS_WINDOWS" -eq 1 ]]; then
      HOST_EXE_EXT=".exe"
    fi
    CXX="$ROOT_DIR/.llvm-mingw/bin/${MINGW_TRIPLE}-clang++${HOST_EXE_EXT}"
    DEFINES=(-DLIBHEIF_STATIC_BUILD -DLIBDE265_STATIC_BUILD)
    EXTRA_LIBS=(-lwinpthread)
    LINK_FLAGS=(-static)
  else
    CXX="${CXX:-c++}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      EXTRA_LIBS=(-framework CoreFoundation -framework VideoToolbox)
    fi
  fi

  LIBHEIF_LIBS=(-lheif -lde265 -lx265 -laom -ldav1d -lsharpyuv)

  "$CXX" -x c "${DEFINES[@]+"${DEFINES[@]}"}" "$ROOT_DIR/tests/smoke_test.c" \
    -I "$DIST_DIR/include" -L "$DIST_DIR/lib" \
    "${LIBHEIF_LIBS[@]}" "${EXTRA_LIBS[@]+"${EXTRA_LIBS[@]}"}" "${LINK_FLAGS[@]+"${LINK_FLAGS[@]}"}" \
    -o "$BUILD_DIR/smoke_test$EXE_SUFFIX"

  "$CXX" -x c "${DEFINES[@]+"${DEFINES[@]}"}" "$ROOT_DIR/tests/codec_test.c" \
    -I "$DIST_DIR/include" -L "$DIST_DIR/lib" \
    "${LIBHEIF_LIBS[@]}" "${EXTRA_LIBS[@]+"${EXTRA_LIBS[@]}"}" "${LINK_FLAGS[@]+"${LINK_FLAGS[@]}"}" \
    -o "$BUILD_DIR/codec_test$EXE_SUFFIX"
else
  echo "==> Skipping build (--no-build), using pre-built binaries in $BUILD_DIR"
fi

if [[ "$CAN_RUN" -eq 0 ]]; then
  echo "==> Built for $TARGET, but cannot execute it on this host ($(uname -s) $(uname -m)); skipping execution."
  exit 0
fi

FAIL=0

run_case() {
  local file="$1"
  local expect_alpha="$2"
  if ! "$BUILD_DIR/smoke_test$EXE_SUFFIX" "$file" "$expect_alpha"; then
    FAIL=1
  fi
}

run_case "$LIBHEIF_DIR/examples/example.heic" 0
run_case "$LIBHEIF_DIR/examples/example.avif" 0
run_case "$LIBHEIF_DIR/tests/data/with-alpha-512x512.heic" 1
run_case "$LIBHEIF_DIR/tests/data/simple_osm_tile_alpha.avif" 1
run_case "$LIBHEIF_DIR/tests/data/clap_cropped.avif" 0
run_case "$LIBHEIF_DIR/tests/data/conformance_window_padding.heic" 0

if ! "$BUILD_DIR/codec_test$EXE_SUFFIX" "$BUILD_DIR"; then
  FAIL=1
fi

exit "$FAIL"
