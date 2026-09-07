# openjpeg

The [OpenJPEG](https://github.com/uclouvain/openjpeg) command-line programs — the open-source JPEG 2000 codec. A single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/openjpeg/actions/workflows/openjpeg.yml/badge.svg)](https://github.com/unpins/openjpeg/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install openjpeg`.

Encode, decode and inspect JPEG 2000 images.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin openjpeg --unpin-program=opj_compress -i in.png -o out.jp2
unpin openjpeg --unpin-program=opj_decompress -i in.jp2 -o out.png
```

Or install them and call each by name, which is usually what you want:

```bash
unpin install openjpeg
opj_compress -i in.png -o out.jp2
```

`unpin install openjpeg` creates all three commands.

## Programs

| program | what it does |
|---|---|
| `opj_compress` | encode a PNG, TIFF, BMP, PNM/PAM, PGX, TGA or raw image to JPEG 2000 |
| `opj_decompress` | decode JPEG 2000 to PNG, TIFF, BMP, PNM, PGX, TGA or raw |
| `opj_dump` | print a JPEG 2000 codestream's structure |

Encoding is lossless unless you ask for a rate (`-r`) or a quality (`-q`).
Each program prints its options with `-h`.

## Build locally

```bash
nix build github:unpins/openjpeg
./result/bin/openjpeg --unpin-program=opj_dump -h
```

Or run directly:

```bash
nix run github:unpins/openjpeg
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/openjpeg/releases) page has standalone binaries for manual download.

## Build notes

- One binary holds all three tools. It answers to `--unpin-program=<tool>` and,
  once installed, to each tool's own name; `libopenjp2` and the external codecs
  are linked once and shared.
- PNG, TIFF and LCMS2 are linked in statically on every platform — no sidecar
  DLLs or shared objects. libtiff brings its codecs with it, so a TIFF
  compressed with LZW, Deflate, PackBits, LZMA or Zstd reads too. WebP-in-TIFF
  reads on Linux and macOS but not on Windows.
- Multithreaded encoding and decoding (`-threads`) is on everywhere, on POSIX
  threads or, on Windows, the native Win32 ones.
- The build checks itself: it encodes a small image and reads it back through
  PPM, PNG, TIFF, BMP and TGA, and fails unless the pixels come back unchanged.
  That runs wherever the build machine can execute what it just built.
- **Windows** is built with mingw. The codec tools (disabled there by default)
  are re-enabled; libtiff's static link closure is recovered by putting
  `libjpeg.pc` back on the pkg-config path (`libtiff-4.pc` requires it).
