# OpenJPEG ships three command-line tools — opj_compress (encode),
# opj_decompress (decode) and opj_dump (codestream info). To honour the unpins
# one-pkg-one-bin rule we post-link them into a single multicall binary at
# $out/bin/openjpeg (a busybox-style dispatcher named after the package, as the
# unpins CI resolves result/bin/<package-name>); `lib.withAliases` then embeds
# the three tool names as an UNPIN_META block so unpin's installer recreates the
# argv[0] shims.
#
# Why a post-link route (no source patch): each tool is a separate CMake
# executable that compiles its OWN copy of the bin helpers (convert / convertbmp
# / index / color / opj_getopt / converttif / convertpng) alongside its main, so
# the three tools share no helper archive — only libopenjp2 plus the external
# image libs (png/tiff/lcms2/z). Per tool we therefore rename every strong
# defined global in its objects (`main` → <tool>_main, any other foo →
# <tool>__foo) so the three `main`s — and the duplicated helper symbols — no
# longer collide, then link the shared libopenjp2 + image libs ONCE. objcopy
# rewrites definitions AND relocations, so each tool keeps calling its own
# (renamed) helpers. The shared nix-lib dispatcher (lib.multicallDispatcherC)
# drives the final link; a bare `openjpeg` lists its three tools and exits 0.
#
# The archive + -l link list is read straight out of each tool's CMake link.txt
# at build time, so the exact store paths, threading libs and image codecs the
# build actually configured are reused verbatim on every platform (musl ELF /
# Mach-O / mingw) — no hard-coded dependency set to drift.
#
# Shared by the native `build` (pkgsStatic) and the `windowsBuild`
# (mingwStaticCross) paths; isDarwin/isWindows come from the INPUT derivation's
# stdenv (under windowsBuild `pkgs` is the x86_64-linux root — the cross lives
# inside mingwStaticCross — so `pkgs.stdenv` would wrongly say "not Windows").
{ lib }:
{ pkgs, opj }:
let
  isDarwin = opj.stdenv.hostPlatform.isDarwin or false;
  isWindows = opj.stdenv.hostPlatform.isWindows or false;

  multicall = opj.overrideAttrs (old: {
    pname = "openjpeg-multi";
    outputs = [ "out" ];

    # Build static libopenjp2 + the three CLIs (not the shared lib the nixpkgs
    # expr asks for — we re-link the tools ourselves) and drop the test tree.
    # Appended last so they win: over the expr's BUILD_SHARED_LIBS=TRUE, and over
    # the BUILD_CODEC=OFF that mingwStaticCross injects for Windows (the codec is
    # exactly the three tools we want — they cross-compile fine with the mingw
    # png/tiff/lcms2 in buildInputs).
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-DBUILD_SHARED_LIBS:BOOL=FALSE"
      "-DBUILD_TESTING:BOOL=FALSE"
      "-DBUILD_CODEC:BOOL=ON"
    ];

    postBuild = (old.postBuild or "") + ''
      set -e
      # Keep an absolute output dir, then work from the directory that holds the
      # tools' CMakeFiles (src/bin/jp2): CMake writes each tool's link.txt with
      # paths — objects, libopenjp2.a, the @rsp file — RELATIVE to that link CWD,
      # so harvesting and the final link must run from there too. Discover it
      # rather than hard-code the layout.
      ROOT="$PWD"
      MC="$ROOT/mc"; mkdir -p "$MC"
      JP2="$(dirname "$(dirname "$(find . -type d -name 'opj_compress.dir' -print -quit)")")"
      cd "$JP2"
      TOOLS="opj_compress opj_decompress opj_dump"

      # Each tool's object dir holds its main plus its private copies of the bin
      # helpers; grab them all. CMake names objects <src>.c.o on ELF/Mach-O but
      # <src>.c.obj on MinGW — detect the extension, then glob the dir.
      oext=o
      [ -n "$(find CMakeFiles/opj_compress.dir -name '*.c.obj' -print -quit 2>/dev/null)" ] && oext=obj
      declare -A TOBJ
      for t in $TOOLS; do
        TOBJ[$t]="$(find "CMakeFiles/$t.dir" -name "*.c.$oext" | sort | tr '\n' ' ')"
      done

      # Harvest the link list from the tools' CMake link.txt: every -l* flag and
      # every *.a archive (libopenjp2 plus the external image libs png/tiff/
      # lcms2/z). MinGW CMake puts the libraries in an `@…linkLibs.rsp` response
      # file (and quotes absolute paths), so expand any `@file` token and strip
      # surrounding quotes. Skip the per-tool `objects.a` bundle (its objects are
      # already in MCOBJS, renamed) and `*.dll.a` import libs. Dedup, first-seen
      # order (dependency-correct: a consumer precedes its provider). Relative
      # archive paths resolve because we run from the link CWD ($JP2).
      LIBS=""
      add() { case " $LIBS " in *" $1 "*) ;; *) LIBS="$LIBS $1" ;; esac; }
      classify() {
        local tok="$1"
        tok="''${tok%\"}"; tok="''${tok#\"}"
        case "$tok" in
          *objects.a | *.dll.a) ;;
          -l* | *.a) add "$tok" ;;
        esac
      }
      for t in $TOOLS; do
        for tok in $(tr ' ' '\n' < "CMakeFiles/$t.dir/link.txt"); do
          case "$tok" in
            @*) rf="''${tok#@}"
                [ -f "$rf" ] && for rt in $(tr ' ' '\n' < "$rf"); do classify "$rt"; done ;;
            *)  classify "$tok" ;;
          esac
        done
      done

      # Mach-O leads C symbols with '_'; detect once from a tool's object.
      if $NM --defined-only ''${TOBJ[opj_compress]} 2>/dev/null | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Per tool, build ONE redef map (main → <t>_main, every other strong
      # defined global foo → <t>__foo; skip weak/COMDAT W/V and names with a
      # '.') from the tool's raw object(s), then apply it to each raw object —
      # objcopy rewrites the definition AND every relocation, so a multi-object
      # tool stays internally consistent and the three `main`s (plus the
      # duplicated helper symbols) no longer collide. The renamed raw objects,
      # not an `ld -r` partial, go into the final link: ld64's `-r` demotes a
      # `main` that owns function-local statics from global (T) to local (t),
      # which would make the map empty and leave <t>_main undefined on darwin.
      MCOBJS=""
      for t in $TOOLS; do
        $NM --defined-only ''${TOBJ[$t]} 2>/dev/null \
          | awk -v t="$t" -v up="$up" '
              $2 ~ /^[A-TX-Z]$/ && $2 != "W" && $2 != "V" {
                sym = $3; core = sym
                if (up != "" && index(core, up) == 1) core = substr(core, 2)
                if (index(core, ".") != 0) next
                if (core !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
                if (core == "main") print sym " " up t "_main"
                else                print sym " " up t "__" core
              }' | sort -u > "$MC/$t.redef"
        for o in ''${TOBJ[$t]}; do
          d="$MC/$t.$(basename "$o")"
          cp "$o" "$d"
          [ -s "$MC/$t.redef" ] && $OBJCOPY --redefine-syms="$MC/$t.redef" "$d"
          MCOBJS="$MCOBJS $d"
        done
      done

      # Multicall dispatcher via the shared nix-lib generator — one contract for
      # the whole catalog (argv[0] alias path + a `--unpin-program=NAME` selector
      # on the bare binary). It calls each tool as `<tool>_main(int, char **)` —
      # the symbols the redef map produced just above (opj_compress_main, …). No
      # defaultApplet: a bare or renamed `openjpeg` (CI's smoke.exe) lists its
      # tools on stdout and exits 0, the clean smoke target — every opj_* tool
      # exits 1 even on -h, so a tool can't be the smoke. The generator's own
      # basename strip survives the CI rename. It writes multicall/dispatcher.c
      # relative to the link CWD ($JP2); compile that into $MC where the final
      # link expects $MC/dispatcher.o.
      mkdir -p multicall
      printf '%s\n' $TOOLS > multicall/apps.list
${lib.multicallDispatcherC { name = "openjpeg"; }}
      $CC -O2 -c -o "$MC/dispatcher.o" multicall/dispatcher.c

      # Final link: shared libopenjp2 + image-codec libs, once. On GNU-ld
      # targets wrap the archives in a group to absorb any back-reference; ld64
      # (darwin) rejects --start-group but re-scans archives on its own, so list
      # them plain there.
      if ${if isDarwin then "true" else "false"}; then
        GO=""; GC=""
      else
        GO="-Wl,--start-group"; GC="-Wl,--end-group"
      fi
      # mingw: this manual link bypasses the `-static` the normal
      # mingwStaticCross build applies, so the gcc `mcf` thread model imports
      # libmcfgthread-2.dll next to the .exe — breaking the single-binary
      # promise. Link the runtime fully static so every -l (incl. the driver's
      # implicit -lmcfgthread) resolves to its .a.
      MCF=""
      ${lib.optionalString isWindows ''MCF="-static"''}
      $CC -O2 \
        $MCOBJS "$MC/dispatcher.o" \
        $GO $LIBS $GC -lm $MCF \
        -o "$MC/openjpeg"
      [ -f "$MC/openjpeg" ] || mv "$MC/openjpeg.exe" "$MC/openjpeg"
      cd "$ROOT"
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/share/man/man1"
      install -m755 mc/openjpeg "$out/bin/openjpeg"
      for a in opj_compress opj_decompress opj_dump; do ln -s openjpeg "$out/bin/$a"; done

      # Man pages live in the source tree (doc/man/man1/<tool>.1); ship all three.
      mandir=""
      for d in ../doc/man/man1 doc/man/man1 "$src/doc/man/man1"; do
        [ -f "$d/opj_compress.1" ] && mandir="$d" && break
      done
      if [ -n "$mandir" ]; then
        for m in opj_compress opj_decompress opj_dump; do
          [ -f "$mandir/$m.1" ] && cp "$mandir/$m.1" "$out/share/man/man1/$m.1"
        done
      fi
      runHook postInstall
    '';
  });

  aliased = lib.withAliases pkgs
    {
      primary = "openjpeg";
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/openjpeg" ] && mv "$out/bin/openjpeg" "$out/bin/openjpeg.exe"
  '';
})
else aliased
