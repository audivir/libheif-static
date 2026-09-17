# libheif-static

Static build of [libheif](https://github.com/strukturag/libheif) with the HEVC, AV1, and WebP
codec dependencies it needs (libde265, x265, libaom, dav1d, libwebp) vendored as git submodules.

## Prerequisites

- macOS or Linux with Xcode Command Line Tools / a C++ toolchain installed
- `git`
- [Homebrew](https://brew.sh) on macOS (used to install missing build tools automatically)
- On Linux: `cmake`, `ninja-build`, `meson`, `nasm`, `pkg-config` installed via your package manager

## Installation

Clone the repo with submodules:

```shell
git clone --recurse-submodules <repo-url>
cd libheif-static
```

## Usage

Run the build script:

```shell
./build.sh
```

This builds `libde265`, `x265`, `libaom`, `dav1d`, and `libwebp` (for `libsharpyuv`) as static
libraries, then links a static `libheif.a` with all codec plugins enabled. Output is installed
under `dist/`:

- `dist/lib/*.a`: static libraries
- `dist/include/`: headers

Pass `--clean` to remove previous build output first, and `--jobs N` to control parallelism.

To run the smoke tests (decodes sample HEIC/AVIF files through the built static `libheif.a`):

```shell
./tests/run_smoke_tests.sh
```

## Acknowledgments

This repository builds and vendors the following upstream projects, unmodified, as git
submodules under `vendor/`. Credit goes to their respective authors:

- [libheif](https://github.com/strukturag/libheif) by Dirk Farin and contributors
- [libde265](https://github.com/strukturag/libde265) by Dirk Farin, struktur AG, and contributors
- [x265](https://bitbucket.org/multicoreware/x265_git) by MulticoreWare, Inc. and contributors
- [libaom](https://aomedia.googlesource.com/aom) by the Alliance for Open Media
- [dav1d](https://code.videolan.org/videolan/dav1d) by VideoLAN and dav1d authors
- [libwebp](https://github.com/webmproject/libwebp) by Google Inc.

## License

MIT for this repository's own code. See NOTICE for the licenses of the vendored libraries and
the resulting static-library artifacts, some of which are copyleft (GPL/LGPL).
