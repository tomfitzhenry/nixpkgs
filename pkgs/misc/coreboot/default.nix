{
  lib,
  stdenv,
  fetchgit,
  coreboot-toolchain,
  pkg-config,
  python3,
  cbfstool,
}:

let
  defaultVersion = "26.06";

  # coreboot source without its 3rdparty blob submodules. coreboot itself is
  # free software; the 3rdparty repos (FSP, microcode, vendor blobs) are not,
  # so they are not fetched by default. Boards that need them supply them via
  # `mkCoreboot`'s `files` argument.
  defaultSrc = fetchgit {
    url = "https://review.coreboot.org/coreboot";
    rev = "0c3c7f09b0da2bb2056bb796654356032848eadd";
    hash = "sha256-lnO2U/VZC5IhvTF0ZGfoy4K/1YXojeMVIdcBi8rAOFo=";
    fetchSubmodules = false;
  };

  # cbfstool links against vboot's host library, so every coreboot build needs
  # it. Unlike the other 3rdparty submodules it is free software (BSD), so it
  # is provided by default.
  corebootVboot = fetchgit {
    url = "https://github.com/coreboot/vboot.git";
    rev = "5c360ef458b0a013d8a6d47724bb0fffb5accbcf";
    hash = "sha256-BZdyUPa9RD2txjFfgcyEQEG+Z6yPJpXRdwTe1ExwaSs=";
  };

  # Render a Kconfig value for coreboot's `.config`:
  # - booleans become y/n
  # - integers are written bare
  # - string values (e.g. CONFIG_PAYLOAD_FILE) are quoted
  # - derivations/paths (e.g. a payload ELF) coerce to their store path and
  #   are quoted
  renderValue =
    value:
    if lib.isBool value then
      if value then "y" else "n"
    else if lib.isInt value then
      toString value
    else if value == "y" || value == "n" then
      value
    else if builtins.isString value && builtins.match "[0-9]+" value != null then
      value
    else
      ''"${value}"'';

  # Keys are given without the `CONFIG_` prefix.
  configName = name: if lib.hasPrefix "CONFIG_" name then name else "CONFIG_${name}";

  # Licenses introduced by the files copied into the build tree (e.g. non-free
  # blobs like FSP or Intel ME). They propagate to the ROM's `meta.license` so
  # that `nixpkgs.config.allowUnfree` gates the build.
  fileLicenses =
    files:
    lib.concatMap (
      v:
      if !(builtins.isAttrs v) then
        [ ]
      else
        (builtins.tryEval (lib.toList (v.meta.license or [ ]))).value or [ ]
    ) (lib.attrValues files);

  # Build a coreboot ROM for a board. `mkCoreboot` is the generic builder:
  # pick a defconfig (or provide a defconfig file), add Kconfig options, inject
  # blobs into the build tree, and optionally arrange the flash as an FMAP
  # normal/fallback layout.
  mkCoreboot = lib.makeOverridable (
    {
      version ? null,
      src ? null,
      # Name of a config file in coreboot's `configs/` directory, or an
      # alternative defconfig file via `defconfigFile`. Exactly one is needed.
      defconfig ? null,
      defconfigFile ? null,
      # RFC42-style coreboot Kconfig options, e.g.
      #   config = {
      #     PAYLOAD_ELF = "y";
      #     PAYLOAD_FILE = "/nix/store/.../some-payload.elf";
      #   };
      # Payloads (EDK2, ...) are embedded by setting the relevant PAYLOAD_*
      # options here.
      config ? { },
      # Shorthand for embedding an ELF payload (a derivation or store path):
      # sets PAYLOAD_ELF/PAYLOAD_FILE. Prefer this to spelling those options
      # in `config` by hand.
      payload ? null,
      # Files or directories to place in the build tree before configuring,
      # keyed by their path in the tree. Used to inject blobs that are not part
      # of the coreboot source, e.g.
      #   files = {
      #     "3rdparty/fsp" = fspSrc;
      #     "blobs/me.bin" = ./me.bin;
      #   };
      # The blobs are then referenced from `config` (e.g. `ME_BIN_PATH =
      # "blobs/me.bin"`).
      files ? { },
      # Partition the flash with an FMAP into a normal and a fallback CBFS
      # region, and populate both slots. This enables A/B firmware updates: a
      # new build is written into the fallback slot and booted once (then
      # adopted or rolled back), so a bad update never bricks the device.
      # `fmap` is an attrset:
      #   fmap = {
      #     # The flashmap descriptor (a `.fmd` file).
      #     fmd = ./myboard.fmd;
      #     # A cbfs_fmap_region_hint() override selecting the slot from the
      #     # CMOS boot_option byte.
      #     fmapBootC = ./fmap_boot.c;
      #     # Mainboard directory the FMAP wiring is added to.
      #     mainboardDir = "src/mainboard/vendor/board";
      #     # The two CBFS region names. Default to coreboot's conventional
      #     # names.
      #     normalRegion ? "COREBOOT",
      #     fallbackRegion ? "COREBOOT_B",
      #   };
      fmap ? null,
      # Files from `build/` to copy into the output directory.
      filesToInstall ? [ "build/coreboot.rom" ],
      installDir ? "$out",
      extraMakeFlags ? [ ],
      extraMeta ? { },
      # Extra native build inputs, e.g. for boards whose build tools have
      # additional dependencies.
      extraNativeBuildInputs ? [ ],
      ...
    }@args:
    assert lib.asserts.assertMsg (
      (defconfig != null) != (defconfigFile != null)
    ) "mkCoreboot: pass exactly one of `defconfig` or `defconfigFile`";
    let
      # `fmap` with the region-name defaults filled in.
      fmap' =
        if fmap == null then
          null
        else
          fmap
          // {
            normalRegion = fmap.normalRegion or "COREBOOT";
            fallbackRegion = fmap.fallbackRegion or "COREBOOT_B";
          };

      # vboot is required to build cbfstool, so it is always present; the
      # caller's files and the FMAP wiring take precedence.
      allFiles = {
        "3rdparty/vboot" = corebootVboot;
      }
      // files
      // (lib.optionalAttrs (fmap' != null) {
        "${fmap'.mainboardDir}/${baseNameOf fmap'.fmd}" = fmap'.fmd;
        "${fmap'.mainboardDir}/fmap_boot.c" = fmap'.fmapBootC;
      });

      # coreboot config implied by `payload` and `fmap`; the caller's `config`
      # wins.
      config' =
        (lib.optionalAttrs (fmap' != null) {
          FMDFILE = "${fmap'.mainboardDir}/${baseNameOf fmap'.fmd}";
        })
        // (lib.optionalAttrs (payload != null) {
          PAYLOAD_ELF = "y";
          PAYLOAD_FILE = payload;
        })
        // config;

      hasPayload =
        payload != null
        || lib.any (name: lib.hasPrefix "CONFIG_PAYLOAD_" (configName name)) (lib.attrNames config);
    in
    stdenv.mkDerivation (finalAttrs: {
      pname = "coreboot-${if defconfig != null then defconfig else "custom"}";
      version = if version == null then defaultVersion else version;
      src = if src == null then defaultSrc else src;

      nativeBuildInputs = [
        coreboot-toolchain.i386
        pkg-config
        python3
      ]
      ++ lib.optional (fmap' != null) cbfstool
      ++ extraNativeBuildInputs;

      enableParallelBuilding = true;
      dontStrip = true;
      dontPatchELF = true;

      postPatch = ''
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (path: v: ''
            mkdir -p "$(dirname '${path}')"
            # -T so the file/dir lands at `path` even when it already exists
            # (e.g. the empty submodule dirs left by fetchSubmodules = false).
            cp -rT ${v} '${path}'
          '') allFiles
        )}
        ${lib.optionalString (fmap' != null) ''
          # Link the slot-selection override into every stage; coreboot looks
          # up the boot region once per stage.
          printf 'all-y += fmap_boot.c\n' >> ${fmap'.mainboardDir}/Makefile.mk
        ''}
        patchShebangs util/xcompile/xcompile
        patchShebangs util/genbuild_h/genbuild_h.sh
      '';

      configurePhase = ''
        runHook preConfigure

        ${
          if defconfigFile != null then
            # -m so the resulting .config is writable (store paths are 0444)
            "install -m 0644 ${defconfigFile} .config"
          else
            "cp configs/config.${defconfig} .config"
        }

        ${lib.optionalString hasPayload ''
          sed -i -e '/^CONFIG_PAYLOAD_NONE=y$/d' .config
        ''}

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: value: "printf '%s\\n' '${configName name}=${renderValue value}' >> .config"
          ) config'
        )}

        make olddefconfig

        runHook postConfigure
      '';

      postBuild = lib.optionalString (fmap' != null) ''
        # Populate the fallback slot with a copy of the normal slot, so both
        # are bootable from the start.
        cbfstool build/coreboot.rom copy -r ${fmap'.fallbackRegion} -R ${fmap'.normalRegion}
      '';

      makeFlags = [
        "BUILD_TIMELESS=1"
        "CONFIG_ANY_TOOLCHAIN=y"
      ]
      ++ extraMakeFlags;

      installPhase = ''
        runHook preInstall

        mkdir -p ${installDir}
        cp ${lib.concatStringsSep " " filesToInstall} ${installDir}

        runHook postInstall
      '';

      meta = {
        homepage = "https://www.coreboot.org";
        description = "Coreboot firmware";
        license = [ lib.licenses.gpl2 ] ++ (fileLicenses allFiles);
        maintainers = with lib.maintainers; [ tomfitzhenry ];
      }
      // extraMeta;
    })
    // removeAttrs args [
      "extraMeta"
      "defconfig"
      "defconfigFile"
      "files"
      "fmap"
      "payload"
      "extraNativeBuildInputs"
    ]
  );
in
{
  inherit mkCoreboot;
}
