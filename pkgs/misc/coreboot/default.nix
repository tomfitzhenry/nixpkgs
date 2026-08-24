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

  # Source for the ASUS Chromebook C300SA (google/cyan, variant terra) build.
  # Tom Fitzhenry's fork of coreboot, on top of upstream main: it drops
  # USE_GOOGLE_FSP so terra can use the public Braswell FSP from 3rdparty/fsp
  # instead of Google's custom FSP binary (the two FSPs carry byte-identical
  # MemoryInit UPD defaults, so the variants work unchanged).
  # https://github.com/tomfitzhenry/coreboot/tree/cyan-public-fsp
  terraSrc = fetchgit {
    url = "https://github.com/tomfitzhenry/coreboot";
    rev = "d8da1aeb2e8e57ac76a4d6b0fa17398ea90a745c";
    hash = "sha256-TXBrU6pBP8X05lzr6M0bl1H87qxFMEl6UUtcNfmm+z8=";
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

  # MrChromebox's fork of coreboot's 3rdparty/blobs repo. Some older boards'
  # blobs (e.g. the Braswell google/cyan FSP, EC firmware, flash descriptor and
  # Intel ME) were dropped from the upstream blobs repo, and only survive here.
  corebootBlobsMrChromebox =
    fetchgit {
      url = "https://github.com/MrChromebox/blobs.git";
      rev = "62a8b7c85602ba6eb38e366fd7220eee77446251";
      hash = "sha256-Pv2fPdvUVfAGUQXkZ1l0atZJwpnAvOa/rR2gQF95YyU=";
    }
    // {
      meta = {
        description = "MrChromebox fork of coreboot's binary blobs repo (has older boards' blobs)";
        homepage = "https://github.com/MrChromebox/blobs";
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

  # coreboot's 3rdparty/intel-microcode submodule: Intel CPU microcode updates
  # (free software), needed by Intel boards that enable microcode in CBFS.
  # It is not fetched as part of `defaultSrc`; boards that need it inject it via
  # `buildCoreboot`'s `files` argument. Pinned to the rev coreboot itself uses.
  corebootIntelMicrocode = fetchgit {
    url = "https://review.coreboot.org/intel-microcode";
    rev = "98f8d817ca3d560c48ae988bd805d1b53b48a631";
    hash = "sha256-hJfuxnHxHAxoTFAdgzontCl2pl5ad222I8BGyHO+MxQ=";
  };

  # coreboot's 3rdparty/fsp submodule: mainline Intel FSP binaries. Terra uses
  # the public Braswell FSP (BSWFSP.fd); it is not fetched as part of
  # `defaultSrc`/`terraSrc` because FSP binaries are not free software, so the
  # terra build injects it via `buildCoreboot`'s `files` argument. Pinned to
  # the rev `terraSrc`'s .gitmodules pins (7cb9638a8d2233017fcc37e446bc8656bb27e92e).
  corebootFsp =
    fetchgit {
      url = "https://review.coreboot.org/fsp.git";
      rev = "7cb9638a8d2233017fcc37e446bc8656bb27e92e";
      hash = "sha256-bl7AKYs+ixei+04keVlJn5Hf0AlmwI/68E9iWOY0wB4=";
    }
    // {
      meta = {
        description = "Mainline Intel FSP binaries (coreboot 3rdparty/fsp)";
        homepage = "https://review.coreboot.org/plugins/gitiles/fsp";
        # FSP binaries are distributed under Intel's restrictive FSP license.
        license = lib.licenses.unfree;
        maintainers = with lib.maintainers; [ tomfitzhenry ];
      };
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
    else if builtins.match "0x[0-9a-fA-F]+" value != null then
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

  # coreboot firmware with EDK2's UEFI payload for the ASUS Chromebook C300SA
  # (google/cyan, variant terra), built directly as a full 8MiB ROM. Built from
  # `terraSrc` (Tom Fitzhenry's coreboot fork), which lets terra use the public
  # Intel FSP instead of Google's custom FSP; everything else uses
  # `defaultSrc` (nixpkgs' coreboot). The fork's config.google_terra is a plain
  # build-test defconfig (PAYLOAD_NONE); the `config` options turn it into a
  # full ROM.
  corebootUefi_terra = buildCoreboot {
    src = terraSrc;
    defconfig = "google_terra";
    config = {
      # UEFI payload; the fork's PAYLOAD_NONE is dropped by buildCoreboot when
      # a PAYLOAD_* option is set.
      PAYLOAD_ELF = "y";
      PAYLOAD_FILE = edk2.corebootPayload.payload;
      # EC firmware, flash descriptor and Intel ME; not in the upstream blobs
      # repo, only in MrChromebox's fork.
      HAVE_IFD_BIN = "y";
      IFD_BIN_PATH = "3rdparty/blobs/mainboard/google/cyan/terra/flashdescriptor.bin";
      HAVE_ME_BIN = "y";
      ME_BIN_PATH = "3rdparty/blobs/soc/intel/bsw/me.bin";
      EC_GOOGLE_CHROMEEC_FIRMWARE_EXTERNAL = "y";
      EC_GOOGLE_CHROMEEC_FIRMWARE_FILE = "3rdparty/blobs/mainboard/google/cyan/terra/ec.RW.flat";
      # UEFI variable store. Enabled explicitly: the payload is a prebuilt
      # EDK2 ELF (PAYLOAD_ELF), not coreboot's in-tree PAYLOAD_EDK2, so
      # SMMSTORE's `default y if PAYLOAD_EDK2` never fires. SMMSTORE_SIZE
      # is left at its default (0x80000).
      SMMSTORE = "y";
    };
    files = {
      # EC firmware, flash descriptor and Intel ME; not in the upstream blobs
      # repo, only in MrChromebox's fork.
      "3rdparty/blobs" = corebootBlobsMrChromebox;
      # Public Braswell FSP, consumed via FSP_USE_REPO (BSWFSP.fd).
      "3rdparty/fsp" = corebootFsp;
      # Intel CPU microcode, consumed by the Braswell microcode update.
      "3rdparty/intel-microcode" = corebootIntelMicrocode;
    };
    # ecrw.hash (the EC firmware digest) is computed with openssl.
    extraNativeBuildInputs = [ openssl ];
    filesToInstall = [ "build/coreboot.rom" ];
  };
in
{
  inherit
    buildCoreboot
    corebootBlobs
    corebootBlobsMrChromebox
    corebootFsp
    corebootIntelMicrocode
    corebootUefi_terra
    ;

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
