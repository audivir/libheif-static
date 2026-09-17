#!/usr/bin/env bash
#
# Builds libheif and its codec dependencies (libde265, x265, libaom, dav1d) as
# static libraries, then links a fully static libheif.
#
# Usage: ./build.sh [--jobs N] [--clean] [--target native|windows-amd64|windows-arm64]
#
# windows-* targets use the llvm-mingw toolchain (auto-downloaded into
# .llvm-mingw/, no vcpkg needed), either cross-compiled from macOS/Linux or
# natively from Git Bash on Windows (--target native auto-detects there).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_DIR="$ROOT_DIR/vendor"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
CLEAN=0
TARGET="native"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs) JOBS="$2"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    --target) TARGET="$2"; shift 2 ;;
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
  windows-amd64) TARGET_SUFFIX="-windows-amd64"; MINGW_TRIPLE="x86_64-w64-mingw32"; MINGW_CMAKE_PROCESSOR="AMD64"; MESON_CPU_FAMILY="x86_64" ;;
  windows-arm64) TARGET_SUFFIX="-windows-arm64"; MINGW_TRIPLE="aarch64-w64-mingw32"; MINGW_CMAKE_PROCESSOR="ARM64"; MESON_CPU_FAMILY="aarch64" ;;
  *) echo "Unknown --target: $TARGET (expected native, windows-amd64, or windows-arm64)" >&2; exit 1 ;;
esac

BUILD_DIR="$ROOT_DIR/build$TARGET_SUFFIX"
PREFIX="$ROOT_DIR/dist$TARGET_SUFFIX"

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

CMAKE_COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)

MESON_CROSS_ARGS=()

if [[ "$TARGET" != "native" ]]; then
  MINGW_DIR="$ROOT_DIR/.llvm-mingw"
  # only the Windows-hosted llvm-mingw release ships .exe binaries.
  HOST_EXE_EXT=""
  if [[ "$HOST_IS_WINDOWS" -eq 1 ]]; then
    HOST_EXE_EXT=".exe"
  fi
  if [[ ! -x "$MINGW_DIR/bin/${MINGW_TRIPLE}-clang${HOST_EXE_EXT}" ]]; then
    echo "==> Downloading llvm-mingw toolchain"
    if [[ "$HOST_IS_WINDOWS" -eq 1 ]]; then
      case "$(uname -m)" in
        aarch64|arm64) ASSET_PATTERN="ucrt-aarch64.zip" ;;
        *) ASSET_PATTERN="ucrt-x86_64.zip" ;;
      esac
    else
      case "$(uname -s)" in
        Darwin) ASSET_PATTERN="ucrt-macos-universal.tar.xz" ;;
        Linux) ASSET_PATTERN="ucrt-ubuntu-22.04-x86_64.tar.xz" ;;
        *) echo "ERROR: unsupported host OS for building for Windows: $(uname -s)" >&2; exit 1 ;;
      esac
    fi
    DOWNLOAD_URL="$(curl -sL https://api.github.com/repos/mstorsjo/llvm-mingw/releases/latest \
      | grep -o "\"browser_download_url\": *\"[^\"]*${ASSET_PATTERN}\"" \
      | sed -E 's/.*"(https[^"]+)"/\1/')"
    if [[ -z "$DOWNLOAD_URL" ]]; then
      echo "ERROR: could not find an llvm-mingw release asset matching $ASSET_PATTERN" >&2
      exit 1
    fi
    mkdir -p "$MINGW_DIR"
    case "$DOWNLOAD_URL" in
      *.zip)
        # Git Bash's tar can't extract .zip; use PowerShell's Expand-Archive instead.
        ARCHIVE="$BUILD_DIR/llvm-mingw.zip"
        EXTRACT_DIR="$BUILD_DIR/llvm-mingw-extract"
        curl -sL "$DOWNLOAD_URL" -o "$ARCHIVE"
        mkdir -p "$EXTRACT_DIR"
        WIN_ARCHIVE="$(cygpath -w "$ARCHIVE")"
        WIN_EXTRACT_DIR="$(cygpath -w "$EXTRACT_DIR")"
        echo "==> Expanding $WIN_ARCHIVE to $WIN_EXTRACT_DIR"
        powershell.exe -NoProfile -Command \
          "Expand-Archive -Path '$WIN_ARCHIVE' -DestinationPath '$WIN_EXTRACT_DIR' -Force"
        INNER_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d)"
        if [[ -z "$INNER_DIR" ]]; then
          echo "ERROR: extracting $ARCHIVE produced no top-level directory under $EXTRACT_DIR" >&2
          exit 1
        fi
        cp -R "$INNER_DIR"/. "$MINGW_DIR"/
        rm -rf "$EXTRACT_DIR" "$ARCHIVE"
        ;;
      *)
        ARCHIVE="$BUILD_DIR/llvm-mingw.archive"
        curl -sL "$DOWNLOAD_URL" -o "$ARCHIVE"
        tar -xf "$ARCHIVE" -C "$MINGW_DIR" --strip-components=1
        rm -f "$ARCHIVE"
        ;;
    esac

    if [[ ! -x "$MINGW_DIR/bin/${MINGW_TRIPLE}-clang${HOST_EXE_EXT}" ]]; then
      echo "ERROR: llvm-mingw extraction did not produce the expected compiler binary." >&2
      echo "Expected: $MINGW_DIR/bin/${MINGW_TRIPLE}-clang${HOST_EXE_EXT}" >&2
      echo "Contents of $MINGW_DIR:" >&2
      ls -la "$MINGW_DIR" >&2 || true
      echo "Contents of $MINGW_DIR/bin (if present):" >&2
      ls -la "$MINGW_DIR/bin" >&2 || true
      exit 1
    fi
  fi

  # toolchain.cmake/cross-file.ini are read as file content, so they miss Git
  # Bash's argv-only POSIX->Windows path translation; convert explicitly.
  MINGW_DIR_FILE="$MINGW_DIR"
  PREFIX_FILE="$PREFIX"
  if [[ "$HOST_IS_WINDOWS" -eq 1 ]]; then
    MINGW_DIR_FILE="$(cygpath -m "$MINGW_DIR")"
    PREFIX_FILE="$(cygpath -m "$PREFIX")"
  fi

  TOOLCHAIN_FILE="$BUILD_DIR/toolchain.cmake"
  cat > "$TOOLCHAIN_FILE" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR $MINGW_CMAKE_PROCESSOR)
set(CMAKE_C_COMPILER $MINGW_DIR_FILE/bin/${MINGW_TRIPLE}-clang${HOST_EXE_EXT})
set(CMAKE_CXX_COMPILER $MINGW_DIR_FILE/bin/${MINGW_TRIPLE}-clang++${HOST_EXE_EXT})
set(CMAKE_AR $MINGW_DIR_FILE/bin/${MINGW_TRIPLE}-ar${HOST_EXE_EXT})
set(CMAKE_RANLIB $MINGW_DIR_FILE/bin/${MINGW_TRIPLE}-ranlib${HOST_EXE_EXT})
set(CMAKE_RC_COMPILER $MINGW_DIR_FILE/bin/${MINGW_TRIPLE}-windres${HOST_EXE_EXT})
set(CMAKE_FIND_ROOT_PATH $MINGW_DIR_FILE/$MINGW_TRIPLE $PREFIX_FILE)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
  CMAKE_COMMON+=(-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE")

  CROSS_FILE="$BUILD_DIR/cross-file.ini"
  cat > "$CROSS_FILE" <<EOF
[binaries]
c = '$MINGW_DIR_FILE/bin/${MINGW_TRIPLE}-clang${HOST_EXE_EXT}'
cpp = '$MINGW_DIR_FILE/bin/${MINGW_TRIPLE}-clang++${HOST_EXE_EXT}'
ar = '$MINGW_DIR_FILE/bin/${MINGW_TRIPLE}-ar${HOST_EXE_EXT}'
strip = '$MINGW_DIR_FILE/bin/${MINGW_TRIPLE}-strip${HOST_EXE_EXT}'
windres = '$MINGW_DIR_FILE/bin/${MINGW_TRIPLE}-windres${HOST_EXE_EXT}'
pkg-config = 'pkg-config'

[host_machine]
system = 'windows'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU_FAMILY'
endian = 'little'
EOF
  MESON_CROSS_ARGS=(--cross-file "$CROSS_FILE")

  # avoid picking up the host's incompatible-architecture .pc files.
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
fi

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# 1. libde265 (static)
echo "==> Building libde265"
LIBDE265_BUILD="$BUILD_DIR/libde265"
cmake -S "$EXT_DIR/libde265" -B "$LIBDE265_BUILD" -G Ninja \
  "${CMAKE_COMMON[@]}" \
  -DENABLE_SDL=OFF \
  -DBUILD_SHARED_LIBS=OFF
cmake --build "$LIBDE265_BUILD" -j "$JOBS"
cmake --install "$LIBDE265_BUILD"

# 2. x265 (static)
# x265 only installs x265.pc when `git describe --tags` succeeds; shallow clones have no tags.
if [[ "$(git -C "$EXT_DIR/x265" rev-parse --is-shallow-repository)" == "true" ]]; then
  echo "==> Fetching full history for x265 (needed for its pkg-config generation)"
  git -C "$EXT_DIR/x265" fetch --unshallow --tags
fi

echo "==> Building x265"
X265_BUILD="$BUILD_DIR/x265"
cmake -S "$EXT_DIR/x265/source" -B "$X265_BUILD" -G Ninja \
  "${CMAKE_COMMON[@]}" \
  -DENABLE_SHARED=OFF \
  -DENABLE_CLI=OFF \
  -DSTATIC_LINK_CRT=ON
cmake --build "$X265_BUILD" -j "$JOBS"
cmake --install "$X265_BUILD"

# 3. libaom (static)
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

# 4. dav1d (static, via meson/ninja)
echo "==> Building dav1d"
DAV1D_BUILD="$BUILD_DIR/dav1d"
meson setup "$DAV1D_BUILD" "$EXT_DIR/dav1d" \
  --prefix="$PREFIX" \
  --libdir=lib \
  --default-library=static \
  --buildtype=release \
  -Denable_tools=false \
  -Denable_tests=false \
  "${MESON_CROSS_ARGS[@]+"${MESON_CROSS_ARGS[@]}"}" \
  --reconfigure 2>/dev/null || \
meson setup "$DAV1D_BUILD" "$EXT_DIR/dav1d" \
  --prefix="$PREFIX" \
  --libdir=lib \
  --default-library=static \
  --buildtype=release \
  -Denable_tools=false \
  -Denable_tests=false \
  "${MESON_CROSS_ARGS[@]+"${MESON_CROSS_ARGS[@]}"}"
ninja -C "$DAV1D_BUILD" -j "$JOBS"
ninja -C "$DAV1D_BUILD" install

# 5. libwebp (static, only for libsharpyuv)
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

# 6. libheif (static, with all codec plugins baked in)
echo "==> Building libheif"
LIBHEIF_BUILD="$BUILD_DIR/libheif"
cmake -S "$EXT_DIR/libheif" -B "$LIBHEIF_BUILD" -G Ninja \
  "${CMAKE_COMMON[@]}" \
  -DCMAKE_C_FLAGS="-DLIBDE265_STATIC_BUILD -DLIBHEIF_STATIC_BUILD" \
  -DCMAKE_CXX_FLAGS="-DLIBDE265_STATIC_BUILD -DLIBHEIF_STATIC_BUILD" \
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

# 7. Make pkg-config files relocatable
# CMake/meson bake in the absolute build-time prefix; make it relative instead.
echo "==> Making pkg-config files relocatable"
for PC_FILE in "$PREFIX"/lib/pkgconfig/*.pc; do
  [[ -e "$PC_FILE" ]] || continue
  # shellcheck disable=SC2016 # ${pcfiledir} is a pkg-config variable, not a shell one
  sed -i.bak 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$PC_FILE"
  rm -f "$PC_FILE.bak"
done

# 8. Verify all expected pkg-config files are present
# catches x265.pc-style install gaps in any dependency.
echo "==> Verifying pkg-config files"
MISSING_PC=0
for PC_NAME in libheif libde265 x265 aom dav1d libsharpyuv; do
  if [[ ! -e "$PREFIX/lib/pkgconfig/$PC_NAME.pc" ]]; then
    echo "ERROR: missing $PREFIX/lib/pkgconfig/$PC_NAME.pc" >&2
    MISSING_PC=1
  fi
done
if [[ "$MISSING_PC" -eq 1 ]]; then
  exit 1
fi

echo ""
echo "==> Done. Static libraries and headers installed under: $PREFIX"
echo "    Libraries: $PREFIX/lib"
echo "    Headers:   $PREFIX/include"
find "$PREFIX/lib" -maxdepth 1 -name "*.a" -exec echo "    {}" \;
