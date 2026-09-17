#!/usr/bin/env bash
#
# Build libheif and all of its codec dependencies (libde265, x265, libaom, dav1d)
# as static libraries, then link a fully static libheif.
#
# Usage: ./build.sh [--jobs N] [--clean]
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_DIR="$ROOT_DIR/external"
BUILD_DIR="$ROOT_DIR/build"
PREFIX="$ROOT_DIR/dist"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) JOBS="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ "$CLEAN" -eq 1 ]]; then
  echo "==> Cleaning previous build/dist directories"
  rm -rf "$BUILD_DIR" "$PREFIX"
fi

mkdir -p "$BUILD_DIR" "$PREFIX/lib" "$PREFIX/include"

echo "==> Checking build tools"
NEEDED_BREW_PKGS=()
command -v cmake  >/dev/null 2>&1 || NEEDED_BREW_PKGS+=(cmake)
command -v ninja  >/dev/null 2>&1 || NEEDED_BREW_PKGS+=(ninja)
command -v meson  >/dev/null 2>&1 || NEEDED_BREW_PKGS+=(meson)
command -v nasm   >/dev/null 2>&1 || NEEDED_BREW_PKGS+=(nasm)
command -v pkg-config >/dev/null 2>&1 || NEEDED_BREW_PKGS+=(pkg-config)

if [[ ${#NEEDED_BREW_PKGS[@]} -gt 0 ]]; then
  if command -v brew >/dev/null 2>&1; then
    echo "==> Installing missing build tools via Homebrew: ${NEEDED_BREW_PKGS[*]}"
    brew install "${NEEDED_BREW_PKGS[@]}"
  else
    echo "ERROR: Missing build tools (${NEEDED_BREW_PKGS[*]}) and Homebrew is not installed." >&2
    echo "Install Homebrew (https://brew.sh) or install these tools manually, then re-run." >&2
    exit 1
  fi
fi

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# Common static-build CMake flags
CMAKE_COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)

########################################
# 1. libde265 (static)
########################################
echo "==> Building libde265"
LIBDE265_BUILD="$BUILD_DIR/libde265"
cmake -S "$EXT_DIR/libde265" -B "$LIBDE265_BUILD" -G Ninja \
  "${CMAKE_COMMON[@]}" \
  -DENABLE_SDL=OFF \
  -DBUILD_SHARED_LIBS=OFF
cmake --build "$LIBDE265_BUILD" -j "$JOBS"
cmake --install "$LIBDE265_BUILD"

########################################
# 2. x265 (static)
########################################
echo "==> Building x265"
X265_BUILD="$BUILD_DIR/x265"
cmake -S "$EXT_DIR/x265/source" -B "$X265_BUILD" -G Ninja \
  "${CMAKE_COMMON[@]}" \
  -DENABLE_SHARED=OFF \
  -DENABLE_CLI=OFF \
  -DSTATIC_LINK_CRT=ON
cmake --build "$X265_BUILD" -j "$JOBS"
cmake --install "$X265_BUILD"

########################################
# 3. libaom (static)
########################################
echo "==> Building libaom"
LIBAOM_BUILD="$BUILD_DIR/libaom"
cmake -S "$EXT_DIR/libaom" -B "$LIBAOM_BUILD" -G Ninja \
  "${CMAKE_COMMON[@]}" \
  -DENABLE_SHARED=OFF \
  -DENABLE_STATIC=ON \
  -DENABLE_EXAMPLES=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_TOOLS=OFF \
  -DENABLE_DOCS=OFF
cmake --build "$LIBAOM_BUILD" -j "$JOBS"
cmake --install "$LIBAOM_BUILD"

########################################
# 4. dav1d (static, via meson/ninja)
########################################
echo "==> Building dav1d"
DAV1D_BUILD="$BUILD_DIR/dav1d"
meson setup "$DAV1D_BUILD" "$EXT_DIR/dav1d" \
  --prefix="$PREFIX" \
  --libdir=lib \
  --default-library=static \
  --buildtype=release \
  -Denable_tools=false \
  -Denable_tests=false \
  --reconfigure 2>/dev/null || \
meson setup "$DAV1D_BUILD" "$EXT_DIR/dav1d" \
  --prefix="$PREFIX" \
  --libdir=lib \
  --default-library=static \
  --buildtype=release \
  -Denable_tools=false \
  -Denable_tests=false
ninja -C "$DAV1D_BUILD" -j "$JOBS"
ninja -C "$DAV1D_BUILD" install

########################################
# 5. libwebp (static, only for libsharpyuv)
########################################
echo "==> Building libwebp (libsharpyuv)"
LIBWEBP_BUILD="$BUILD_DIR/libwebp"
cmake -S "$EXT_DIR/libwebp" -B "$LIBWEBP_BUILD" -G Ninja \
  "${CMAKE_COMMON[@]}" \
  -DWEBP_BUILD_ANIM_UTILS=OFF \
  -DWEBP_BUILD_CWEBP=OFF \
  -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF \
  -DWEBP_BUILD_IMG2WEBP=OFF \
  -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPINFO=OFF \
  -DWEBP_BUILD_LIBWEBPMUX=OFF \
  -DWEBP_BUILD_WEBPMUX=OFF \
  -DWEBP_BUILD_EXTRAS=OFF
cmake --build "$LIBWEBP_BUILD" -j "$JOBS"
cmake --install "$LIBWEBP_BUILD"

########################################
# 6. libheif (static, with all codec plugins baked in)
########################################
echo "==> Building libheif"
LIBHEIF_BUILD="$BUILD_DIR/libheif"
cmake -S "$EXT_DIR/libheif" -B "$LIBHEIF_BUILD" -G Ninja \
  "${CMAKE_COMMON[@]}" \
  -DWITH_LIBDE265=ON \
  -DWITH_X265=ON \
  -DWITH_AOM_DECODER=ON \
  -DWITH_AOM_ENCODER=ON \
  -DWITH_DAV1D=ON \
  -DWITH_LIBSHARPYUV=ON \
  -DWITH_EXAMPLES=OFF \
  -DBUILD_TESTING=OFF \
  -DWITH_GDK_PIXBUF=OFF \
  -DENABLE_PLUGIN_LOADING=OFF
cmake --build "$LIBHEIF_BUILD" -j "$JOBS"
cmake --install "$LIBHEIF_BUILD"

echo ""
echo "==> Done. Static libraries and headers installed under: $PREFIX"
echo "    Libraries: $PREFIX/lib"
echo "    Headers:   $PREFIX/include"
find "$PREFIX/lib" -maxdepth 1 -name "*.a" -exec echo "    {}" \;
