# Changelog

## [Unreleased]

## [2.5.4-2] - 2026-09-26

### Fixed

- On Windows, `opj_compress` refused TIFF files compressed with Zstd or LZMA —
  `ZSTD compression support is not configured` — while the Linux and macOS
  builds of the same version read them. Those two codecs were switched off in
  the shared mingw build of libtiff, on the grounds that nothing exercised
  them; this package does. They are on now, and the `.exe` grows by about
  680 KB because of it. TIFF's WebP codec stays off on Windows: it would drag
  a whole image library in for a variant almost nothing writes.

- The README showed `unpin openjpeg opj_compress …`, which does not work — the
  program name goes in `--unpin-program=`. Corrected, and the
  installed-command form is now shown alongside it. The build notes described a
  fold recipe the package stopped using, and said nothing about which TIFF
  compressions the tools can read.

### Changed

- The build now encodes a small image and reads it back through PPM, PNG, TIFF,
  BMP and TGA, failing unless the pixels come back unchanged, and checks that
  `-threads` really decodes. Nothing before this tested that the tools could
  read or write anything at all: the format list they print is a fixed string,
  compiled in whether or not the library behind it is.

- The smoke test now requires all three program names, in order, instead of
  matching `opj_compress` anywhere in the output — which any error message
  listing the programs would also have satisfied.

## [2.5.4-1] - 2026-06-06

First release: `opj_compress`, `opj_decompress` and `opj_dump` in one binary,
for Linux, macOS and Windows.
