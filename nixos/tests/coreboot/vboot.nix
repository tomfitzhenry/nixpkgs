# Test coreboot's vboot (verified boot) A/B firmware fallback on the QEMU q35
# board. The flash is partitioned by vboot's vboot-rwab-8M.fmd into two RW
# slots (RW_SECTION_A / RW_SECTION_B), each with a signed VBLOCK and a CBFS
# FW_MAIN. vboot selects a slot from its NVRAM (VBNV) state machine, which on
# this board is stored in CMOS.
#
# The test boots slot A, writes a VBNV block (from the guest, with a valid
# CRC-8) that requests slot B once, warm-reboots, and asserts that vboot
# selects B. Because nothing commits B as successfully booted (the EDK2
# payload has no vboot kernel API), another warm reboot exhausts the try
# count and vboot automatically falls back to slot A.
{ config, lib, ... }:
let
  # coreboot with vboot enabled and two RW slots, with EDK2's UEFI payload
  # embedded (and signed with the vboot devkeys) in both slots.
  corebootRom = config.node.pkgs.mkCoreboot {
    defconfig = "emulation_qemu_x86_q35_smm_tseg";
    payload = config.node.pkgs.edk2.corebootPayload.payload;
    config = {
      VBOOT = "y";
      VBOOT_SLOTS_RW_AB = "y";
      VBOOT_MOCK_SECDATA = "y";
      # Spew level so vboot's firmware selection messages are on the serial
      # console.
      DEFAULT_CONSOLE_LOGLEVEL_8 = "y";
    };
  };

  # Write a VBNV block into CMOS. coreboot's vbnv_cmos.c stores the 16-byte
  # VBNV record at CMOS register CONFIG_VBOOT_VBNV_OFFSET (0x2c on q35) + 14
  # (the RTC's byte-0 offset). The record uses vboot's V1 layout:
  #   offset 0: header; signature (mask 0xc0) = 0x40
  #   offset 1: boot flags; low nibble = TRY_COUNT
  #   offset 7: boot2 flags; 0x04 = FW_TRIED, 0x08 = TRY_NEXT, 0x03 = result
  #   offset 15: CRC-8 (poly x^8+x^2+x+1) over offsets 0..14
  # See coreboot src/security/vboot/vbnv_layout.h and vboot
  # firmware/2lib/include/2nvstorage_fields.h.
  vbnvtool = config.node.pkgs.stdenv.mkDerivation {
    pname = "vbnvtool";
    version = "test";
    dontUnpack = true;
    src = config.node.pkgs.writeText "vbnvtool.c" ''
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <sys/io.h>

      #define VBNV_CMOS_BASE 58 /* 0x2c (q35 VBOOT_VBNV_OFFSET) + 14 */
      #define VBNV_SIZE 16
      #define CRC_OFFSET 15
      #define HEADER_SIGNATURE 0x40
      #define BOOT_TRY_COUNT_MASK 0x0f
      #define BOOT2_RESULT_MASK 0x03
      #define BOOT2_TRY_NEXT 0x08
      #define FW_RESULT_SUCCESS 2

      static unsigned char cmos_read(unsigned char addr)
      {
        outb(addr, 0x70);
        return inb(0x71);
      }

      static void cmos_write(unsigned char addr, unsigned char val)
      {
        outb(addr, 0x70);
        outb(val, 0x71);
      }

      /* coreboot src/security/vboot/vbnv.c crc8_vbnv(). */
      static unsigned char crc8_vbnv(const unsigned char *data, int len)
      {
        unsigned int crc = 0;
        int i, j;

        for (j = len; j; j--, data++) {
          crc ^= (*data << 8);
          for (i = 8; i; i--) {
            if (crc & 0x8000)
              crc ^= (0x1070 << 3);
            crc <<= 1;
          }
        }
        return (unsigned char)(crc >> 8);
      }

      static void read_block(unsigned char *b)
      {
        int i;
        for (i = 0; i < VBNV_SIZE; i++)
          b[i] = cmos_read(VBNV_CMOS_BASE + i);
      }

      static void write_block(unsigned char *b)
      {
        int i;
        b[CRC_OFFSET] = crc8_vbnv(b, CRC_OFFSET);
        for (i = 0; i < VBNV_SIZE; i++)
          cmos_write(VBNV_CMOS_BASE + i, b[i]);
      }

      int main(int argc, char **argv)
      {
        unsigned char b[VBNV_SIZE];
        int i;

        if (argc != 2) {
          fprintf(stderr, "usage: %s request-b|commit|show\n", argv[0]);
          return 2;
        }

        if (iopl(3) < 0) {
          perror("iopl");
          return 1;
        }

        read_block(b);

        if (!strcmp(argv[1], "request-b")) {
          /* Request slot B once, then fall back to A unless committed. */
          memset(b, 0, sizeof(b));
          b[0] = HEADER_SIGNATURE;
          b[1] = (b[1] & ~BOOT_TRY_COUNT_MASK) | 1;
          b[7] = BOOT2_TRY_NEXT;
        } else if (!strcmp(argv[1], "commit")) {
          /* Mark the slot we booted as successfully booted. */
          b[7] = (b[7] & ~BOOT2_RESULT_MASK) | FW_RESULT_SUCCESS;
          b[1] &= ~BOOT_TRY_COUNT_MASK;
        } else if (!strcmp(argv[1], "show")) {
          for (i = 0; i < VBNV_SIZE; i++)
            printf("%02x%s", b[i], i == VBNV_SIZE - 1 ? "\n" : " ");
          return 0;
        } else {
          fprintf(stderr, "unknown command: %s\n", argv[1]);
          return 2;
        }

        write_block(b);
        return 0;
      }
    '';
    buildPhase = ''
      runHook preBuild
      cc -D_DEFAULT_SOURCE -o vbnvtool $src
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp vbnvtool $out/bin/
      runHook postInstall
    '';
  };
in
{
  name = "coreboot-vboot";

  meta = with lib.maintainers; {
    maintainers = [ tomfitzhenry ];
  };

  nodes.machine =
    { lib, ... }:
    {
      virtualisation.useBootLoader = true;
      virtualisation.useEFIBoot = true;

      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = false;

      # Read the kernel output from the serial console so it can be matched
      # deterministically with wait_for_console_text.
      boot.kernelParams = [ "console=ttyS0" ];

      # EDK2's UefiPayloadPkg can only read AHCI/SATA disks (it has no virtio
      # block driver), so replace the default virtio disk with one on the q35
      # AHCI controller.
      virtualisation.qemu.drives = lib.mkForce [ ];

      # The harness mounts its host/guest shared directories as virtiofs and
      # marks them needed for boot. Those QEMU devices are injected through
      # `virtualisation.qemu.options` (see below), so replacing that option
      # would leave the guest unable to mount them and stage 1 would fail. This
      # test only talks to the guest over the serial console, so drop the
      # shares instead.
      virtualisation.sharedDirectories = lib.mkForce { };

      # Boot via the coreboot vboot firmware with the EDK2 payload, instead of
      # OVMF. `useEFIBoot` would otherwise attach OVMF as a pflash drive,
      # which QEMU prefers over `-bios`, so coreboot would never run.
      virtualisation.qemu.options = lib.mkForce [
        "-bios ${corebootRom}/coreboot.rom"
        "-machine q35"
        "-drive file=$NIX_DISK_IMAGE,format=qcow2,if=none,id=cbroot,cache=writeback,werror=report"
        "-device ide-hd,drive=cbroot,bus=ide.0,serial=root"
      ];

      environment.systemPackages = [ vbnvtool ];
    };

  testScript = ''
    machine.start(allow_reboot=True)

    def reboot():
      # Guest-initiated warm reboot, which preserves CMOS (and thus VBNV),
      # rather than a QEMU power cycle.
      assert machine.shell is not None
      machine.shell.send(b"reboot\n")
      machine.connected = False

    with subtest("Boots the current RW slot A"):
      machine.wait_for_console_text("Slot A is selected")
      machine.wait_for_unit("multi-user.target")

    with subtest("Request slot B once and warm-reboot into it"):
      machine.succeed("vbnvtool request-b")
      reboot()
      machine.wait_for_console_text("Slot B is selected")
      machine.wait_for_unit("multi-user.target")

    with subtest("B was not committed, so vboot falls back to A"):
      reboot()
      machine.wait_for_console_text("try_count used up; falling back to slot A")
      machine.wait_for_console_text("Slot A is selected")
      machine.wait_for_unit("multi-user.target")
  '';
}
