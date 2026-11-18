/*
  remapper routes a keyboard and a mouse into a libvirt VM, and the VM sees
  them as USB HID: what Windows drives without a driver.

  `host` runs libvirtd, the daemon and ./fake-input.py, which plays the
  numpad, the keyboard and the mouse. Its VM, `nested`, boots a kernel and
  ./nested-init.sh, which logs each input event with its device's bus to
  the serial console. The domain has PS/2 (q35's i8042) and virtio input
  already, so events that reached either would show it.
*/
{ mkTest }:
mkTest {
  name = "remapper";
  backend = "qemu";
  phases.test = {
    script = ../remapper.py;
    after = [ "boot" ];
  };

  nodes.host =
    { pkgs, lib, ... }:
    let
      remapper = pkgs.python3Packages.callPackage ../../pkgs/remapper { inherit (pkgs) libvirt; };
      python = pkgs.python3.withPackages (p: [ p.evdev ]);
      json = pkgs.formats.json { };
      config = json.generate "remapper.json" {
        numpad = {
          vendor = "1234";
          product = "0001";
          keys = [ "KEY_KP0" ];
        };
        domain = "nested";
        forward = [
          {
            vendor = "1234";
            product = "0002";
          }
          {
            vendor = "1234";
            product = "0003";
          }
        ];
        bindings = [
          {
            key = "KEY_KP1";
            action.do = "guest";
          }
          {
            key = "KEY_KP2";
            action.do = "host";
          }
        ];
      };

      kernel = pkgs.linuxPackages.kernel;
      modules = [
        # PS/2: what an event would land on if the USB pair did not win.
        "i8042"
        "atkbd"
        "psmouse"
        "xhci_pci"
        "usbhid"
        "hid_generic"
        "virtio_pci"
        "virtio_input"
        "evdev"
      ];
      moduleTree = pkgs.makeModulesClosure {
        kernel = lib.getOutput "modules" kernel;
        firmware = pkgs.runCommand "no-firmware" { } "mkdir -p $out/lib/firmware";
        rootModules = modules;
      };
      init = pkgs.replaceVarsWith {
        src = ./nested-init.sh;
        isExecutable = true;
        replacements = {
          shell = "${pkgs.busybox}/bin/sh";
          path = lib.makeBinPath [
            pkgs.busybox
            pkgs.kmod
          ];
          modules = lib.concatStringsSep " " modules;
        };
      };
      initrd = pkgs.makeInitrdNG {
        name = "nested-initrd";
        compressor = "zstd";
        contents = [
          {
            source = init;
            target = "/init";
          }
          {
            source = "${moduleTree}/lib/modules";
            target = "/lib/modules";
          }
          { source = pkgs.busybox; }
          { source = pkgs.kmod; }
        ];
      };
    in
    {
      vivarium.nestedVirtualization = true;
      vivarium.memory = "2048M";
      vivarium.cpus = 2;

      virtualisation.libvirtd.enable = true;
      services.udev.packages = [ remapper ];

      environment.etc."nested.xml".text = ''
        <domain type="kvm">
          <name>nested</name>
          <memory unit="MiB">256</memory>
          <vcpu>1</vcpu>
          <os>
            <type arch="x86_64" machine="q35">hvm</type>
            <kernel>${kernel}/bzImage</kernel>
            <initrd>${initrd}/initrd</initrd>
            <cmdline>console=ttyS0 quiet</cmdline>
          </os>
          <!-- Without ACPI the q35 PCIe ports never power xHCI or virtio. -->
          <features><acpi/><apic/></features>
          <devices>
            <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>
            <controller type="usb" model="qemu-xhci"/>
            <input type="keyboard" bus="virtio"/>
            <input type="mouse" bus="virtio"/>
            <serial type="file">
              <source path="/var/log/libvirt/qemu/nested-console.log"/>
            </serial>
          </devices>
        </domain>
      '';

      systemd.services.fake-input = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${python}/bin/python ${./fake-input.py} /run/fake-input";
      };
      systemd.services.remapper = {
        wantedBy = [ "multi-user.target" ];
        after = [
          "fake-input.service"
          "libvirtd.service"
        ];
        requires = [ "libvirtd.service" ];
        serviceConfig = {
          ExecStart = "${lib.getExe remapper} --verbose --config ${config}";
          Restart = "always";
        };
      };
    };
}
