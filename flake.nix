{
  description = "the OpenJPEG (JPEG 2000) command-line tools as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # OpenJPEG installs three CLIs (opj_compress, opj_decompress, opj_dump);
  # nix-lib folds them into one `openjpeg` dispatcher binary that answers to
  # `--unpin-program=<tool>` and to each tool's name as argv[0]. Windows goes
  # through mingw — OpenJPEG is portable CMake C that cross-compiles cleanly
  # (like brotli), and CMake adds -DOPJ_STATIC on a static Windows build so the
  # public API isn't decorated __declspec(dllimport).
  #
  # The canonical binary is named `openjpeg` (= the package name) per the unpins
  # convention — the CI portability/smoke checks resolve `result/bin/<name>`, so
  # the dispatcher must carry the package name; the three tools are its aliases.
  # All three upstream man pages ship.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
      # Add libjpeg's dev to buildInputs: libtiff-4.pc declares
      # `Requires.private: zlib libjpeg`, but the cross/static dep closure does
      # not propagate libjpeg's `.dev` (the .pc lives there), so on mingw
      # `pkg_check_modules(PC_TIFF)` fails on the missing libjpeg.pc and openjpeg
      # leaves TIFF_LIBNAME empty — the tools then fail to link libtiff. Putting
      # libjpeg.pc back on PKG_CONFIG_PATH lets pkg-config resolve tiff's full
      # static closure, which our post-link then harvests from link.txt.
      withOpj = s:
        s.openjpeg.overrideAttrs (o: {
          buildInputs = (o.buildInputs or [ ]) ++ [ (s.libjpeg.dev or s.libjpeg) ];
        });
      # Build the three CLIs (BUILD_CODEC) as static executables and drop the
      # shared lib and the test tree. Appended last so they win over the expr's
      # BUILD_SHARED_LIBS=TRUE and over the BUILD_CODEC=OFF mingwStaticCross
      # injects — the codec IS the three tools we ship. nixpkgs doesn't install
      # the tool man pages either, so copy them out of the source tree.
      opjTools = drv: drv.overrideAttrs (o: {
        cmakeFlags = (o.cmakeFlags or [ ]) ++ [
          "-DBUILD_SHARED_LIBS:BOOL=FALSE"
          "-DBUILD_TESTING:BOOL=FALSE"
          "-DBUILD_CODEC:BOOL=ON"
        ];
        postInstall = (o.postInstall or "") + ''
          mkdir -p "$out/share/man/man1"
          for m in opj_compress opj_decompress opj_dump; do
            for d in "$src/doc/man/man1" doc/man/man1 ../doc/man/man1; do
              [ -f "$d/$m.1" ] && cp "$d/$m.1" "$out/share/man/man1/$m.1" && break
            done
          done
        '';
      });
      # Encode/decode guard. The default is lossless, so every leg is a byte
      # comparison of the pixels against the ones that went in rather than a
      # quality threshold, and each leg adds one reader/writer pair to the
      # path: PPM and BMP and TGA are openjpeg's own, PNG brings in libpng,
      # TIFF brings in libtiff. The tools name the formats they accept in a
      # fixed help string that is compiled in whether or not the library
      # behind it is — so the help is not evidence, and this is.
      #
      # The alpha leg goes out through PNG and back because there is no PNM
      # openjpeg will write four components to: it reads PAM and refuses to
      # write it, upstream, in both the distro builds and ours.
      #
      # -threads is asked for twice over: upstream prints that option only
      # when opj_has_thread_support() is true, so the help line is the cheap
      # probe that the build found threads at all, and decoding with two of
      # them is the one that says they work.
      #
      # This sits on the openjpeg derivation, where the three tools are still
      # three programs in $out/bin; the fold into one `openjpeg` happens later
      # and is what the smoke covers. So the guard tests the codecs and the
      # smoke tests the dispatch.
      withRoundTrip = pkgs: drv: drv.overrideAttrs (old: {
        doInstallCheck = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
        installCheckPhase = ''
          runHook preInstallCheck
          b=$out/bin

          # A 32x32 gradient, half of it translucent. 32 is the smallest side
          # the default six resolution levels fit in.
          hex=(); for ((i=0;i<256;i++)); do hex+=("$(printf %02x $i)"); done
          gen() {  # $1 non-empty => append an alpha byte per pixel
            local y x row
            for ((y=0;y<32;y++)); do
              row=
              for ((x=0;x<32;x++)); do
                row="$row\\x''${hex[(x*8)%256]}\\x''${hex[(y*8)%256]}\\x''${hex[((x+y)*4)%256]}"
                if [ -n "$1" ]; then row="$row\\x''${hex[x<16?255:96]}"; fi
              done
              printf "$row"
            done
          }
          { printf 'P6\n32 32\n255\n'; gen ""; } > p.ppm
          { printf 'P7\nWIDTH 32\nHEIGHT 32\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n'; gen a; } > p.pam

          # openjpeg stamps a comment line into every PNM header it writes, so
          # the comparisons are over the 3072 pixel bytes alone.
          enc() { "$b/opj_compress" -i "$1" -o "$2" > /dev/null; }
          dec() { "$b/opj_decompress" -quiet -i "$1" -o "$2" > /dev/null; }
          same() { cmp <(tail -c 3072 "$1") <(tail -c 3072 "$2") || { echo "$3"; exit 1; }; }

          enc p.ppm a.jp2
          dec a.jp2 a.ppm
          same p.ppm a.ppm "the lossless round trip changed the pixels"

          for f in png tif bmp tga; do
            dec a.jp2 "r.$f"
            enc "r.$f" "r_$f.jp2"
            dec "r_$f.jp2" "r_$f.ppm"
            same p.ppm "r_$f.ppm" "the $f round trip changed the pixels"
          done

          enc p.pam pa.jp2
          dec pa.jp2 pa.png
          enc pa.png pb.jp2
          dec pb.jp2 pb.png
          cmp pa.png pb.png || { echo "the alpha channel did not survive the round trip"; exit 1; }

          # -h exits 1 in all three tools, and the phase runs under pipefail,
          # so the help has to be caught in a file before it can be grepped.
          "$b/opj_decompress" -h > help.txt 2>&1 || true
          grep -q -- -threads help.txt || { echo "built without thread support"; exit 1; }
          "$b/opj_decompress" -quiet -threads 2 -i a.jp2 -o t.ppm > /dev/null
          same a.ppm t.ppm "decoding with -threads 2 changed the pixels"

          "$b/opj_dump" -i a.jp2 > dump.txt
          grep -q "x1=32" dump.txt || { echo "opj_dump did not report the geometry"; exit 1; }

          echo "installCheck: lossless round trip exact through PPM, PNG, TIFF, BMP and TGA; alpha kept; threads on"
          runHook postInstallCheck
        '';
      });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "openjpeg";
      # Pure C, so the engine compiles all three CLIs to bitcode and folds
      # them itself — no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        programs = [
          { name = "opj_compress"; }
          { name = "opj_decompress"; }
          { name = "opj_dump"; }
        ];
      };
      # Canonical binary == package name (openjpeg); see header. The dispatcher
      # lists the three tools and exits 0 on a bare or `--help` invocation, and
      # that listing is the only exit-0 path there is: all three tools exit 1
      # even for -h, so none of them can be the smoke target. A non-empty smoke
      # arg is also required — an empty array trips `set -u` empty-array
      # expansion on the macOS runners' bash 3.2.
      #
      # The pattern is the whole list, in order, rather than one name: that is
      # what says every tool survived the fold, and it does not depend on the
      # wording nix-lib wraps the list in. What the tools can actually read and
      # write is the installCheck's job.
      smoke = [ "--help" ];
      smokePattern = "opj_compress, opj_decompress, opj_dump";
      build = pkgs: withRoundTrip pkgs (opjTools (withOpj pkgs.pkgsStatic));
      windowsBuild = pkgs: opjTools (withOpj (ulib.mingwStaticCross pkgs));
    };
}
