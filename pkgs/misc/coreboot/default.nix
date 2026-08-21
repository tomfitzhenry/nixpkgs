{
  lib,
  stdenv,
  fetchgit,
  coreboot-toolchain,
  pkg-config,
  python3,
}:

let
  defaultVersion = "26.06";
  defaultSrc = fetchgit {
    url = "https://review.coreboot.org/coreboot";
    rev = "0c3c7f09b0da2bb2056bb796654356032848eadd";
    hash = "sha256-rL9txaDXUzjkC2ioYmunoNq2+9rz9wpEJ7z3GZrqOH4=";
    fetchSubmodules = true;
  };

  # Render a Kconfig value for coreboot's `.config`:
  # - booleans become y/n
  # - integers are written bare
  # - string values (e.g. CONFIG_PAYLOAD_FILE) are quoted
  renderValue = value:
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

  buildCoreboot = lib.makeOverridable (
    {
      version ? null,
      src ? null,
      # Name of a config file in coreboot's `configs/` directory.
      defconfig,
      # RFC42-style coreboot Kconfig options, e.g.
      #   config = {
      #     PAYLOAD_ELF = "y";
      #     PAYLOAD_FILE = "/nix/store/.../grub-coreboot.elf";
      #   };
      # Payloads (GRUB, EDK2, ...) are embedded by setting the relevant
      # PAYLOAD_* options here.
      config ? {},
      filesToInstall,
      installDir ? "$out",
      extraMakeFlags ? [ ],
      extraMeta ? { },
      ...
    }@args:
    stdenv.mkDerivation (finalAttrs: {
      pname = "coreboot-${defconfig}";
      version = if version == null then defaultVersion else version;
      src = if src == null then defaultSrc else src;

      nativeBuildInputs = [
        coreboot-toolchain.i386
        pkg-config
        python3
      ];

      enableParallelBuilding = true;
      dontStrip = true;
      dontPatchELF = true;

      postPatch = ''
        patchShebangs util/xcompile/xcompile
        patchShebangs util/genbuild_h/genbuild_h.sh
        substituteInPlace payloads/external/*/Makefile --replace "git" "echo"
      '';

      configurePhase = ''
        runHook preConfigure

        cp configs/config.${defconfig} .config

        ${
          lib.optionalString (
            lib.length (
              lib.filter (name: lib.hasPrefix "CONFIG_PAYLOAD_" (configName name)) (lib.attrNames config)
            ) > 0
          ) ''
            sed -i -e '/^CONFIG_PAYLOAD_NONE=y$/d' .config
          ''
        }

        ${
          lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: value: "printf '%s\\n' '${configName name}=${renderValue value}' >> .config"
            ) config
          )
        }

        make olddefconfig

        runHook postConfigure
      '';

      makeFlags = [
        "BUILD_TIMELESS=1"
        "CONFIG_ANY_TOOLCHAIN=y"
      ] ++ extraMakeFlags;

      installPhase = ''
        runHook preInstall

        mkdir -p ${installDir}
        cp ${lib.concatStringsSep " " filesToInstall} ${installDir}

        runHook postInstall
      '';

      meta =
        {
          homepage = "https://www.coreboot.org";
          description = "Coreboot firmware";
          license = lib.licenses.gpl2;
          maintainers = with lib.maintainers; [ tomfitzhenry ];
        }
        // extraMeta;
    })
    // removeAttrs args [ "extraMeta" ]
  );
in
{
  inherit buildCoreboot;
}
