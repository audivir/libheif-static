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

## License

MIT
