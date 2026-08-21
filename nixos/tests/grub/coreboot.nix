{ config, lib, ... }:
let
  # GRUB as a coreboot payload is only built for i386 (the payload runs in
  # 32-bit protected mode even on x86_64 coreboot systems), so the package is
  # only available on i686/x86_64.
  grubCoreboot = config.node.pkgs.grub2.override { corebootSupport = true; };
in
{
  name = "grub-coreboot";

  meta = with lib.maintainers; {
    maintainers = [ tomfitzhenry ];
  };

  nodes.machine = { ... }: {
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

    with subtest("grub-mkstandalone builds a coreboot payload"):
        # This mirrors coreboot's own default_payload.elf recipe, which is
        # built with grub-mkstandalone -O i386-coreboot.
        machine.succeed(
            "echo 'set timeout=5' > /tmp/grub.cfg && "
            + "${grubCoreboot}/bin/grub-mkstandalone -O i386-coreboot "
            + "-o /tmp/grub-payload.elf "
            + "-d ${grubCoreboot}/lib/grub/i386-coreboot "
            + "--fonts= --themes= --locales= "
            + "/boot/grub/grub.cfg=/tmp/grub.cfg"
        )
        machine.succeed("od -An -tx1 -N4 /tmp/grub-payload.elf | grep '7f 45 4c 46'")
  '';
}
