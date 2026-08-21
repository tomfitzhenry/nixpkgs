{ config, lib, ... }:
let
  # GRUB built for coreboot, from which the payload below is generated.
  grubCoreboot = config.node.pkgs.grubCoreboot;

  # The GRUB payload that coreboot loads. It switches to the serial console,
  # finds the NixOS boot disk by label and chains into the GRUB config that
  # NixOS installed on that disk.
  grubCfg = config.node.pkgs.writeText "grub.cfg" ''
    insmod serial
    insmod terminal
    serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
    terminal_input serial
    terminal_output serial

    insmod ahci
    insmod ata
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    insmod search_label
    search --label --set=root nixos
    configfile /boot/grub/grub.cfg
  '';

  grubCorebootPayload = config.node.pkgs.stdenv.mkDerivation {
    pname = "grub-coreboot-payload";
    version = "test";
    nativeBuildInputs = [ grubCoreboot ];
    buildCommand = ''
      mkdir -p $out
      grub-mkstandalone -O i386-coreboot -o $out/grub-coreboot.elf \
        -d ${grubCoreboot}/lib/grub/i386-coreboot \
        --modules='normal' \
        --install-modules='normal configfile serial terminal part_msdos part_gpt ext2 search search_label search_fs_uuid linux linux16 ahci ata pata usbms gzio all_video' \
        --fonts= --themes= --locales= \
        /boot/grub/grub.cfg=${grubCfg}
    '';
  };

  # coreboot firmware (for the QEMU q35 emulation board) with the GRUB payload
  # embedded.
  corebootRom = config.node.pkgs.buildCoreboot {
    defconfig = "emulation_qemu_x86_q35_smm_tseg";
    config = {
      PAYLOAD_ELF = "y";
      PAYLOAD_FILE = "${grubCorebootPayload}/grub-coreboot.elf";
      DEFAULT_CONSOLE_LOGLEVEL_5 = "y";
    };
    filesToInstall = [ "build/coreboot.rom" ];
  };
in
{
  name = "coreboot-boot-grub";

  meta = with lib.maintainers; {
    maintainers = [ tomfitzhenry ];
  };

  nodes.machine =
    { lib, ... }:
    {
      virtualisation.useBootLoader = true;

      # GRUB (as the coreboot payload) can only read AHCI/SATA disks, so
      # replace the default virtio disk with one on the q35 AHCI controller.
      virtualisation.qemu.drives = lib.mkForce [ ];
      virtualisation.qemu.options = [
        "-bios ${corebootRom}/coreboot.rom"
        "-machine q35"
        "-drive file=$NIX_DISK_IMAGE,format=qcow2,if=none,id=cbroot,cache=writeback,werror=report"
        "-device ide-hd,drive=cbroot,bus=ide.0,serial=root"
      ];

      boot.loader.grub = {
        enable = true;

        # Read GRUB from the serial console so its output can be matched
        # deterministically with wait_for_console_text.
        extraConfig = "serial; terminal_output serial";
      };
      boot.kernelParams = [ "console=ttyS0" ];

      # So the VM can inspect the i386-coreboot target produced by the GRUB
      # coreboot build.
      environment.systemPackages = [ grubCoreboot ];
    };

  testScript = ''
    machine.start()

    with subtest("coreboot build produces the i386-coreboot target"):
        # The coreboot platform modules, including the coreboot-specific ones.
        machine.succeed("test -d ${grubCoreboot}/lib/grub/i386-coreboot")
        machine.succeed("test -f ${grubCoreboot}/lib/grub/i386-coreboot/kernel.img")
        for module in ["cbfs", "cbtime", "cbls", "cbmemc"]:
            machine.succeed(f"test -f ${grubCoreboot}/lib/grub/i386-coreboot/{module}.mod")

    with subtest("Booting via coreboot firmware"):
        machine.wait_for_console_text("coreboot")

    with subtest("Coreboot loads the GRUB payload"):
        machine.wait_for_console_text("GNU GRUB")

    with subtest("GRUB boots the kernel"):
        machine.wait_for_console_text("Linux version")

    with subtest("Reaches multi-user target"):
        machine.wait_for_unit("multi-user.target")
  '';
}
