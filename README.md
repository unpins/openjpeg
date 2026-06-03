# openjpeg

Standalone build of the [OpenJPEG](https://github.com/uclouvain/openjpeg)
command-line programs — the open-source JPEG 2000 codec.

[![CI](https://github.com/unpins/openjpeg/actions/workflows/openjpeg.yml/badge.svg)](https://github.com/unpins/openjpeg/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin openjpeg opj_compress -i in.png -o out.jp2
unpin openjpeg opj_decompress -i in.jp2 -o out.png
```

To install the programs onto your PATH:

```bash
unpin install openjpeg
```

`unpin install openjpeg` creates the `opj_compress`, `opj_decompress`, and `opj_dump` commands.

## Programs

| command           | what it does                              |
| ----------------- | ----------------------------------------- |
| `opj_compress`    | encode PNG/TIFF/BMP/PNM/RAW → JPEG 2000    |
| `opj_decompress`  | decode JPEG 2000 → PNG/TIFF/BMP/PNM/RAW    |
| `opj_dump`        | print a JPEG 2000 codestream's structure  |

## Build locally

```bash
nix build github:unpins/openjpeg
./result/bin/openjpeg
```

Or run directly:

```bash
nix run github:unpins/openjpeg
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/openjpeg/releases) page has standalone binaries for manual download.

## Build notes

- One multicall binary holds all three tools. Each tool compiles its own copy of
  the bin helpers (image conversion + getopt) and shares only `libopenjp2` and
  the external codecs (png/tiff/lcms2/zlib), linked once. The canonical name is
  `openjpeg` (a dispatcher); the three tools dispatch on `argv[0]`.
- The tools are folded together with the post-link `objcopy --redefine-sym`
  recipe (rename each tool's `main` → `<tool>_main`), with the archive/codec
  link list read from CMake's per-tool `link.txt`.
- PNG, TIFF and LCMS2 input/output are linked in statically on every platform —
  no sidecar DLLs or shared objects.
- **Windows** is built with mingw. The codec tools (disabled there by default)
  are re-enabled; libtiff's static link closure is recovered by putting
  `libjpeg.pc` back on the pkg-config path (`libtiff-4.pc` requires it). The
  tools use native Win32 threads, so the `.exe` drags no extra runtime.
