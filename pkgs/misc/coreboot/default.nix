{
  lib,
  stdenv,
  fetchgit,
  openssl,
  coreboot-toolchain,
  pkg-config,
  python3,
  grub2,
  edk2,
}:

let
  defaultVersion = "26.06";

  # coreboot source without its 3rdparty blob submodules. coreboot itself is
  # free software; the 3rdparty repos (FSP, microcode, vendor blobs) are not,
  # so they are not fetched by default. Boards that need them supply them via
  # `buildCoreboot`'s `files` argument.
  defaultSrc = fetchgit {
    url = "https://review.coreboot.org/coreboot";
    rev = "0c3c7f09b0da2bb2056bb796654356032848eadd";
    hash = "sha256-lnO2U/VZC5IhvTF0ZGfoy4K/1YXojeMVIdcBi8rAOFo=";
    fetchSubmodules = false;
  };

  # coreboot's 3rdparty/blobs repository: binary blobs (e.g. AGESA, Intel ME,
  # FSP) required by some mainboards. It is not fetched as part of
  # `defaultSrc` because the blobs are not free software; boards that need them
  # inject the relevant parts via `buildCoreboot`'s `files` argument.
  corebootBlobs =
    fetchgit {
      url = "https://github.com/coreboot/blobs.git";
      rev = "4a8de0324e7d389454ec33cdf66939b653bf6800";
      hash = "sha256-UgerWpdaX0/Lwyx6BJ8AmX1fAsuFHwUmB11633pG+yo=";
    }
    // {
      meta = {
        description = "Binary blobs required by some coreboot mainboards";
        homepage = "https://review.coreboot.org/plugins/gitiles/blobs";
        # Blob licenses vary, but none of them are free software.
        license = lib.licenses.unfree;
        maintainers = with lib.maintainers; [ tomfitzhenry ];
      };
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
  renderValue =
    value:
    if lib.isBool value then
      if value then "y" else "n"
    else if lib.isInt value then
      toString value
    else if value == "y" || value == "n" then
      value
    else if builtins.match "[0-9]+" value != null then
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

  buildCoreboot = lib.makeOverridable (
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
      #     PAYLOAD_FILE = "/nix/store/.../grub-coreboot.elf";
      #   };
      # Payloads (GRUB, EDK2, ...) are embedded by setting the relevant
      # PAYLOAD_* options here.
      config ? { },
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
      filesToInstall,
      installDir ? "$out",
      extraMakeFlags ? [ ],
      extraMeta ? { },
      # Extra native build inputs, e.g. for boards whose build tools have
      # additional dependencies (amdbfwtool needs openssl).
      extraNativeBuildInputs ? [ ],
      ...
    }@args:
    assert lib.asserts.assertMsg (
      (defconfig != null) != (defconfigFile != null)
    ) "buildCoreboot: pass exactly one of `defconfig` or `defconfigFile`";
    let
      # vboot is required to build cbfstool, so it is always present; the
      # caller's files take precedence.
      allFiles = {
        "3rdparty/vboot" = corebootVboot;
      }
      // files;
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
        patchShebangs util/xcompile/xcompile
        patchShebangs util/genbuild_h/genbuild_h.sh
        substituteInPlace payloads/external/*/Makefile --replace "git" "echo"
      '';

      configurePhase = ''
        runHook preConfigure

        ${
          if defconfigFile != null then
            "cp ${defconfigFile} .config"
          else
            "cp configs/config.${defconfig} .config"
        }

        ${lib.optionalString
          (
            lib.length (
              lib.filter (name: lib.hasPrefix "CONFIG_PAYLOAD_" (configName name)) (lib.attrNames config)
            ) > 0
          )
          ''
            sed -i -e '/^CONFIG_PAYLOAD_NONE=y$/d' .config
          ''
        }

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: value: "printf '%s\\n' '${configName name}=${renderValue value}' >> .config"
          ) config
        )}

        make olddefconfig

        runHook postConfigure
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
      "extraNativeBuildInputs"
    ]
  );
in
{
  inherit buildCoreboot corebootBlobs;

  # GRUB built for the coreboot platform (i386-coreboot). To embed GRUB in a
  # coreboot ROM, build a payload with grub-mkstandalone (see coreboot's own
  # default_payload.elf recipe) and point `buildCoreboot`'s `PAYLOAD_FILE` at
  # it.
  grubCoreboot = grub2.override { corebootSupport = true; };

  # coreboot firmware with EDK2's UEFI payload for the PC Engines APU2.
  #
  # The APU2's blobs (AGESA) are redistributable, but under a restrictive AMD
  # license, so the ROM is marked unfree and excluded from binary caches.
  corebootUefi_apu2 = buildCoreboot {
    defconfig = "pcengines_apu2";
    config = {
      # The APU2 defconfig builds secondary payloads (iPXE, Memtest86+) by
      # fetching their sources from the network at build time; disable them.
      PXE = "n";
      MEMTEST_SECONDARY_PAYLOAD = "n";
      PAYLOAD_ELF = "y";
      PAYLOAD_FILE = edk2.corebootPayload.payload;
    };
    files = {
      # AGESA (memory/silicon init), the APU2's only required blob.
      "3rdparty/blobs" = corebootBlobs;
    };
    # amdfwtool, which assembles the AGESA stage, links against OpenSSL.
    extraNativeBuildInputs = [ openssl ];
    filesToInstall = [ "build/coreboot.rom" ];
  };
}
