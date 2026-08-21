{ config, lib, ... }:
let
  # coreboot firmware (for the QEMU q35 emulation board) with EDK2's UEFI
  # payload (UefiPayloadPkg) embedded.
  corebootRom = config.node.pkgs.buildCoreboot {
    defconfig = "emulation_qemu_x86_q35_smm_tseg";
    config = {
      PAYLOAD_ELF = "y";
      PAYLOAD_FILE = config.node.pkgs.edk2.corebootPayload.payload;
      DEFAULT_CONSOLE_LOGLEVEL_5 = "y";
    };
    filesToInstall = [ "build/coreboot.rom" ];
  };
in
{
  name = "coreboot-boot-uefi";

  meta = with lib.maintainers; {
    maintainers = [ tomfitzhenry ];
  };

  nodes.machine =
    { lib, ... }:
    {
      # An ESP with systemd-boot installed, which the EDK2 payload boots from.
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;

      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = false;

      # Read the kernel from the serial console so its output can be matched
      # deterministically with wait_for_console_text.
      boot.kernelParams = [ "console=ttyS0" ];

      # EDK2's UefiPayloadPkg can only read AHCI/SATA disks (it has no virtio
      # block driver), so replace the default virtio disk with one on the q35
      # AHCI controller.
      virtualisation.qemu.drives = lib.mkForce [ ];

      # Boot via coreboot firmware with the EDK2 payload, instead of OVMF.
      # `useEFIBoot` would otherwise attach OVMF as a pflash drive, and QEMU
      # prefers that pflash firmware over `-bios`, so coreboot would never run.
      # Override the QEMU options to drop the pflash drives and boot from the
      # coreboot ROM directly.
      virtualisation.qemu.options = lib.mkForce [
        "-bios ${corebootRom}/coreboot.rom"
        "-machine q35"
        "-drive file=$NIX_DISK_IMAGE,format=qcow2,if=none,id=cbroot,cache=writeback,werror=report"
        "-device ide-hd,drive=cbroot,bus=ide.0,serial=root"
      ];
    };

  testScript = ''
    machine.start()

    with subtest("Booting via coreboot firmware"):
        machine.wait_for_console_text("coreboot")

    with subtest("EDK2 payload boots the kernel"):
        machine.wait_for_console_text("Linux version")

    with subtest("Boots via UEFI (EDK2 payload, not legacy BIOS)"):
        machine.succeed("test -d /sys/firmware/efi")

    with subtest("Reaches multi-user target"):
        machine.wait_for_unit("multi-user.target")
  '';
}
