{
  description = "the OpenJPEG (JPEG 2000) command-line tools as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # OpenJPEG installs three CLIs (opj_compress, opj_decompress, opj_dump);
  # nix-lib folds them into one `openjpeg` dispatcher binary with all three
  # tool names as argv[0]-dispatch UNPIN_META aliases. Windows goes
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
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "openjpeg";
      # Canonical binary == package name (openjpeg); see header. The shared
      # dispatcher lists the three tools on stdout and exits 0 on a bare or
      # `--help` invocation — the three tools themselves exit 1 even on -h, so a
      # tool can't be the smoke target; `openjpeg --help` is the clean smoke. A
      # non-empty smoke arg is also required: an empty array trips `set -u`
      # empty-array expansion on the macOS runners' bash 3.2.
      # Engine self-fold (native Linux + darwin): the unpin-llvm engine compiles
      # OpenJPEG's three CLIs to bitcode and folds them into one `openjpeg`
      # dispatcher. Bare/`--help` lists the three programs and exits 0 (the
      # dispatcher's no-applet path), so the existing smoke still matches
      # `opj_compress` in that listing. Pure C — no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        programs = [
          { name = "opj_compress"; }
          { name = "opj_decompress"; }
          { name = "opj_dump"; }
        ];
      };
      smoke = [ "--help" ];
      smokePattern = "opj_compress";
      build = pkgs: opjTools (withOpj pkgs.pkgsStatic);
      windowsBuild = pkgs: opjTools (withOpj (ulib.mingwStaticCross pkgs));
    };
}
