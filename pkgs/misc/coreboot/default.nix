{
  lib,
  stdenv,
  fetchgit,
  coreboot-toolchain,
  pkg-config,
  python3,
  cbfstool,
  futility,
  openssl,
  edk2,
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

  # coreboot's 3rdparty/blobs repository: binary blobs (e.g. AGESA, Intel ME,
  # FSP) required by some mainboards. It is not fetched as part of `defaultSrc`
  # because the blobs are not free software; boards that need them inject the
  # relevant parts via `mkCoreboot`'s `files` argument.
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

  # coreboot's 3rdparty/fsp submodule: the public Intel FSP binaries. Boards
  # that use `FSP_USE_REPO` consume (e.g.) the Alder Lake-N FSP from here. FSP
  # binaries are not free software, so they are not fetched as part of
  # `defaultSrc`; boards that need them inject the tree via `mkCoreboot`'s
  # `files` argument. Pinned to the rev coreboot 26.06 pins in .gitmodules.
  #
  # https://review.coreboot.org/plugins/gitiles/fsp
  corebootFsp =
    fetchgit {
      url = "https://review.coreboot.org/fsp.git";
      rev = "ca4f8b702db0cb4a1e5bdf5f72396faa089f4137";
      hash = "sha256-+uqiP0B1jnyPCR0ME7LUqVAnahZzADY+jjAoaAQgm3M=";
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

  # coreboot's 3rdparty/intel-microcode submodule: Intel CPU microcode updates
  # (free software). Boards with `USE_CPU_MICROCODE_CBFS_BINS` consume the
  # microcode from here. Pinned to the rev coreboot 26.06 pins in .gitmodules.
  corebootIntelMicrocode = fetchgit {
    url = "https://review.coreboot.org/intel-microcode";
    rev = "98f8d817ca3d560c48ae988bd805d1b53b48a631";
    hash = "sha256-hJfuxnHxHAxoTFAdgzontCl2pl5ad222I8BGyHO+MxQ=";
  };

  # The CWWK CW-ADLN-NAS mainboard is not in mainline 26.06. This is the
  # author's hardware-verified branch: mainline after the 26.06 tag plus the
  # Twin Lake variant (SuperIO COM1 console, live-dumped GPIO, USB-first EDK2
  # boot order, CLKREQ/ASPM fixes) and, on top, the vboot Kconfig block and
  # 16 MiB RW_AB FMAP. Pinning the branch keeps the verified ROM reproducible
  # from nixpkgs without carrying the board as patches.
  #
  # https://github.com/tomfitzhenry/coreboot/tree/cwwk-adln-nas-vboot-verified
  cwwkCorebootSrc = fetchgit {
    url = "https://github.com/tomfitzhenry/coreboot.git";
    rev = "e936df46ff82b00ec8515dddeb8e97f73dfab958";
    hash = "sha256-SqOgvk4euhxqLCCfzyx81yYUsU2iOMsUrYumOELJvII=";
    fetchSubmodules = false;
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

      # vboot builds sign the RW slots with the in-tree `futility`, which
      # links against OpenSSL's libcrypto. CHROMEOS implies VBOOT in Kconfig.
      usesVboot = (config'.VBOOT or "n") == "y" || (config'.CHROMEOS or "n") == "y";
    in
    stdenv.mkDerivation (
      finalAttrs:
      {
        pname = "coreboot-${if defconfig != null then defconfig else "custom"}";
        version = if version == null then defaultVersion else version;
        src = if src == null then defaultSrc else src;

        nativeBuildInputs = [
          coreboot-toolchain.i386
          pkg-config
          python3
        ]
        ++ lib.optional (fmap' != null) cbfstool
        ++ lib.optional usesVboot openssl
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
        ''
        # Kept out of the preceding string so non-vboot builds are unchanged.
        + lib.optionalString usesVboot ''
          # vboot's build scripts (e.g. scripts/getversion.sh) run directly
          # during the futility build and need their interpreters patched.
          patchShebangs 3rdparty/vboot
          # glibc 2.44 (C23) makes strchr()/strrchr() preserve the constness of
          # their argument, so vboot's futility (which assigns the result to a
          # `char *`) now trips -Werror=discarded-qualifiers. Keep the warning
          # but don't let it fail the build.
          substituteInPlace util/futility/Makefile.mk \
            --replace-fail \
              'WERROR="-Werror -Wno-deprecated-declarations"' \
              'WERROR="-Werror -Wno-deprecated-declarations -Wno-error=discarded-qualifiers"'
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
      }
      // removeAttrs args [
        "config"
        "extraMeta"
        "defconfig"
        "defconfigFile"
        "files"
        "fmap"
        "payload"
        "extraNativeBuildInputs"
      ]
    )
  );
  # coreboot with vboot (verified boot) and the EDK2 UEFI payload for the PC
  # Engines APU2, flashed as a full 8 MiB RW_AB image.
  #
  # Mainline coreboot does not support vboot on this board; the patch ports the
  # pcengines fork's support (FMAP, mainboard Kconfig and AMDFW_OUTSIDE_CBFS)
  # onto current mainline. The APU2's AGESA blob is redistributable but under a
  # restrictive AMD license, so the ROM is unfree and excluded from caches.
  #
  # https://github.com/pcengines/coreboot/blob/8d3e714804b1b2bb5bc89e3ffd9cb3c34f8eb0c6/src/mainboard/pcengines/apu2/Kconfig
  apu2VbootRom = mkCoreboot {
    defconfig = "pcengines_apu2_vboot";
    payload = edk2.corebootPayload.payload;
    config = {
      VBOOT = "y";
      VBOOT_SLOTS_RW_AB = "y";
      # The APU2 defconfig builds secondary payloads (iPXE, Memtest86+) by
      # fetching their sources from the network at build time; disable them.
      PXE = "n";
      MEMTEST_SECONDARY_PAYLOAD = "n";
    };
    files = {
      "3rdparty/blobs" = corebootBlobs;
    };
    patches = [ ./apu2-vboot.patch ];
    # amdfwtool, which assembles the AGESA stage, links against OpenSSL.
    extraNativeBuildInputs = [ openssl ];
  };

  # Structural check of the APU2 vboot ROM, runnable without hardware (there is
  # no APU2 QEMU model). It asserts that the vboot RW_AB FMAP and the signed
  # firmware slots are present, that the read-only files (AGESA, spd.bin,
  # romstage) are kept out of the RW slots, and that each VBLOCK signs its
  # FW_MAIN body.
  apu2VbootRomStructureTest = stdenv.mkDerivation {
    pname = "corebootVboot_apu2-rom-structure-test";
    version = defaultVersion;
    dontUnpack = true;
    nativeBuildInputs = [
      cbfstool
      futility
    ];

    buildCommand = ''
      set -euo pipefail
      rom=${apu2VbootRom}/coreboot.rom

      # The FMAP must describe vboot's RO + RW_A + RW_B layout.
      cbfstool "$rom" layout > layout.txt
      for region in GBB COREBOOT VBLOCK_A VBLOCK_B FW_MAIN_A FW_MAIN_B \
        RW_FWID_A RW_FWID_B; do
        grep -q "'$region'" layout.txt
      done

      # AGESA, spd.bin and romstage are read-only: present in COREBOOT...
      cbfstool "$rom" print -r COREBOOT > coreboot.cbfs
      grep -q '^AGESA' coreboot.cbfs
      grep -q 'spd.bin' coreboot.cbfs
      grep -q 'fallback/romstage' coreboot.cbfs

      # ...and absent from both RW slots, which instead carry the payload.
      for slot in A B; do
        cbfstool "$rom" print -r "FW_MAIN_$slot" > "fw_main_$slot.cbfs"
        grep -q 'fallback/ramstage' "fw_main_$slot.cbfs"
        grep -q 'fallback/payload' "fw_main_$slot.cbfs"
        ! grep -q '^AGESA' "fw_main_$slot.cbfs"
        ! grep -q 'spd.bin' "fw_main_$slot.cbfs"
        ! grep -q 'fallback/romstage' "fw_main_$slot.cbfs"
      done

      # Each VBLOCK preamble must sign its FW_MAIN body.
      futility dump_fmap -x "$rom" VBLOCK_A FW_MAIN_A VBLOCK_B FW_MAIN_B \
        > /dev/null
      futility show -f FW_MAIN_A VBLOCK_A | grep -q 'Body verification succeeded'
      futility show -f FW_MAIN_B VBLOCK_B | grep -q 'Body verification succeeded'

      mkdir -p $out
      cp "$rom" $out/coreboot.rom
    '';

    meta = {
      description = "Structural check of the PC Engines APU2 vboot ROM";
      # The test embeds the ROM, which carries the unfree AGESA blob.
      license = [
        lib.licenses.gpl2
        lib.licenses.unfree
      ];
      maintainers = with lib.maintainers; [ tomfitzhenry ];
    };
  };

  # coreboot with vboot (verified boot) and the EDK2 UEFI payload for the CWWK
  # CW-ADLN-NAS, an Intel Alder Lake-N/Twin Lake (N355) NAS board.
  #
  # Built from the author's hardware-verified branch (see `cwwkCorebootSrc`),
  # which already contains the mainboard support, the SuperIO COM1 console, the
  # live-dumped GPIO table and the board's vboot Kconfig block and 16 MiB RW_AB
  # FMAP. The public Intel FSP and the CPU microcode are injected from
  # coreboot's 3rdparty submodules (`files`).
  #
  # The earlier approach (Gerrit change 91908 plus local vboot patches) is
  # superseded by this branch; the Gerrit change remains at
  # https://review.coreboot.org/c/coreboot/+/91908.
  #
  # Runtime VBNV is stored in CMOS with a flash backup (the SoC selects
  # VBOOT_VBNV_CMOS_BACKUP_TO_FLASH), which is why the FMAP needs RW_NVRAM.
  cwwkAdlVbootRom = mkCoreboot {
    src = cwwkCorebootSrc;
    defconfigFile = ./cwwk-adl-cw-adln-nas-twinlake-vboot.config;
    payload = edk2.corebootPayload.payload;
    config = {
      VBOOT = "y";
      VBOOT_SLOTS_RW_AB = "y";
      # EDK2 stores its UEFI variables in SMMSTORE; the 0x80000 default size
      # matches the SMMSTORE region in the FMAP.
      SMMSTORE = "y";
      # Assemble the platform microcode from 3rdparty/intel-microcode.
      CPU_MICROCODE_CBFS_DEFAULT_BINS = "y";
      DEFAULT_CONSOLE_LOGLEVEL_8 = "y";
    };
    files = {
      "3rdparty/fsp" = corebootFsp;
      "3rdparty/intel-microcode" = corebootIntelMicrocode;
    };
    # futility (used to sign the RW slots) links against OpenSSL.
    extraNativeBuildInputs = [ openssl ];
    extraMeta = {
      description = "coreboot firmware with vboot and the EDK2 UEFI payload for the CWWK CW-ADLN-NAS (Intel Twin Lake/N355)";
    };
  };

  # Structural check of the CW-ADLN-NAS vboot ROM, runnable without hardware.
  # It asserts the vboot RW_AB FMAP and signed firmware slots are present, that
  # the RO slot carries the early stages and the RW slots carry ramstage and
  # the payload, and that each VBLOCK signs its FW_MAIN body.
  cwwkAdlVbootRomStructureTest = stdenv.mkDerivation {
    pname = "corebootVboot_cwwkAdl-rom-structure-test";
    version = defaultVersion;
    dontUnpack = true;
    nativeBuildInputs = [
      cbfstool
      futility
    ];

    buildCommand = ''
      set -euo pipefail
      rom=${cwwkAdlVbootRom}/coreboot.rom

      # The FMAP must describe vboot's RO + RW_A + RW_B layout, including the
      # RW_NVRAM region required by the flash-backed VBNV.
      cbfstool "$rom" layout > layout.txt
      for region in GBB COREBOOT VBLOCK_A VBLOCK_B FW_MAIN_A FW_MAIN_B \
        RW_FWID_A RW_FWID_B RW_NVRAM RECOVERY_MRC_CACHE RW_MRC_CACHE SMMSTORE; do
        grep -q "'$region'" layout.txt
      done

      # The early stages and the read-only blobs live in COREBOOT...
      cbfstool "$rom" print -r COREBOOT > coreboot.cbfs
      grep -q 'fallback/romstage' coreboot.cbfs
      grep -q 'fspm.bin' coreboot.cbfs
      grep -q 'cpu_microcode_blob.bin' coreboot.cbfs

      # ...while the RW slots carry ramstage, FSP-S and the payload.
      for slot in A B; do
        cbfstool "$rom" print -r "FW_MAIN_$slot" > "fw_main_$slot.cbfs"
        grep -q 'fallback/ramstage' "fw_main_$slot.cbfs"
        grep -q 'fallback/payload' "fw_main_$slot.cbfs"
        grep -q 'fsps.bin' "fw_main_$slot.cbfs"
      done

      # Each VBLOCK preamble must sign its FW_MAIN body.
      futility dump_fmap -x "$rom" VBLOCK_A FW_MAIN_A VBLOCK_B FW_MAIN_B \
        > /dev/null
      futility show -f FW_MAIN_A VBLOCK_A | grep -q 'Body verification succeeded'
      futility show -f FW_MAIN_B VBLOCK_B | grep -q 'Body verification succeeded'

      mkdir -p $out
      cp "$rom" $out/coreboot.rom
    '';

    meta = {
      description = "Structural check of the CWWK CW-ADLN-NAS vboot ROM";
      # The test embeds the ROM, which carries the unfree Intel FSP.
      license = [
        lib.licenses.gpl2
        lib.licenses.unfree
      ];
      maintainers = with lib.maintainers; [ tomfitzhenry ];
    };
  };
in
{
  inherit
    mkCoreboot
    corebootBlobs
    corebootFsp
    corebootIntelMicrocode
    ;
  corebootVboot_apu2 = apu2VbootRom // {
    passthru = (apu2VbootRom.passthru or { }) // {
      tests = {
        "rom-structure" = apu2VbootRomStructureTest;
      };
    };
  };
  corebootVboot_cwwkAdl = cwwkAdlVbootRom // {
    passthru = (cwwkAdlVbootRom.passthru or { }) // {
      tests = {
        "rom-structure" = cwwkAdlVbootRomStructureTest;
      };
    };
  };
}
