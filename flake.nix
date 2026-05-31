{
  description = "Standalone build of the OpenJPEG tools";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # OpenJPEG installs three CLIs (opj_compress, opj_decompress, opj_dump);
  # ./multicall.nix post-links them into one `openjpeg` dispatcher binary with
  # all three tool names as argv[0]-dispatch UNPIN_META aliases. Windows goes
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
      # The tools pull libjpeg-turbo transitively through libtiff. On riscv64
      # the vanilla libjpeg-turbo fails to build (its RVV SIMD coverage helper
      # references jsimd_can_* symbols the new RVV port never defines); apply the
      # shared nix-lib fix, gated to riscv so other arches keep the cached build.
      # Same one chafa/heif/avif/libwebp use.
      #
      # Also add libjpeg's dev to buildInputs: libtiff-4.pc declares
      # `Requires.private: zlib libjpeg`, but the cross/static dep closure does
      # not propagate libjpeg's `.dev` (the .pc lives there), so on mingw
      # `pkg_check_modules(PC_TIFF)` fails on the missing libjpeg.pc and openjpeg
      # leaves TIFF_LIBNAME empty — the tools then fail to link libtiff. Putting
      # libjpeg.pc back on PKG_CONFIG_PATH lets pkg-config resolve tiff's full
      # static closure, which our post-link then harvests from link.txt.
      withOpj = scope:
        let
          host = scope.stdenv.hostPlatform;
          s = scope.extend (final: prev:
            scope.lib.optionalAttrs host.isRiscV {
              libjpeg = ulib.nativeFixes."libjpeg-turbo" prev;
            });
        in
        s.openjpeg.overrideAttrs (o: {
          buildInputs = (o.buildInputs or [ ]) ++ [ (s.libjpeg.dev or s.libjpeg) ];
        });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "openjpeg";
      # Canonical binary == package name (openjpeg); see header. The dispatcher
      # prints a version banner and exits 0 for any non-tool argv (the three
      # tools themselves exit 1 even on -h), so `openjpeg --version` is the clean
      # smoke target. A non-empty smoke arg is also required: an empty array trips
      # `set -u` empty-array expansion on the macOS runners' bash 3.2.
      smoke = [ "--version" ];
      smokePattern = "2\\.5";
      build = pkgs:
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          { inherit pkgs; opj = withOpj pkgs.pkgsStatic; };
      windowsBuild = pkgs:
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          { inherit pkgs; opj = withOpj (ulib.mingwStaticCross pkgs); };
    };
}
