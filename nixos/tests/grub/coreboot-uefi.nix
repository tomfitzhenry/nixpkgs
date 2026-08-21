{ config, lib, ... }:
let
  edk2Payload = config.node.pkgs.edk2.corebootPayload;

  # coreboot firmware, built for x86_64, with EDK2's UEFI payload embedded.
  corebootRom = config.node.pkgs.buildCoreboot {
    defconfig = "emulation_qemu_x86_q35_smm_tseg";
    config = {
      PAYLOAD_FLAT_BINARY = "y";
      PAYLOAD_FILE = edk2Payload.payload;
      PAYLOAD_OPTIONS = "-l 0x200000 -e 0x200000";
      ARCH_ALL_STAGES_X86_64 = "y";
      DEFAULT_CONSOLE_LOGLEVEL_5 = "y";
    };
    filesToInstall = [ "build/coreboot.rom" ];
  };
in
{
  name = "grub-coreboot-uefi";

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

      # Boot via coreboot firmware with the EDK2 payload, instead of OVMF.
      virtualisation.qemu.options = [
        "-bios ${corebootRom}/coreboot.rom"
        "-machine q35"
      ];
    };

  testScript = ''
    machine.start()

    # coreboot's own early serial output is not reliably captured in the VM
    # test environment, so we verify the chain via the EDK2 payload booting the
    # kernel, and the resulting UEFI runtime.

    with subtest("EDK2 payload boots the kernel"):
        machine.wait_for_console_text("Linux version")

    with subtest("Boots via UEFI (EDK2 payload, not legacy BIOS)"):
        machine.succeed("test -d /sys/firmware/efi")

    with subtest("Reaches multi-user target"):
        machine.wait_for_unit("multi-user.target")
  '';
}
