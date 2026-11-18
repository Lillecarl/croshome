/*
  A remote unlock through the initrd, over WiFi and WireGuard.

  `box` boots plainly, then reboots into `gated`, whose initrd waits at a
  password prompt. `hub` reaches that initrd only through its tunnel and
  answers the prompt over ssh, as hetztop would for shitbox. Two
  mac80211_hwsim radios stand in for the WiFi: the initrd runs an access
  point on wlan1, and boot.initrd.wifi joins it on wlan0.

  `gated` holds all of it, not the first boot: vivarium installs the
  bootloader only after the first boot, so that initrd has no secrets.
  `switch-to-configuration boot` appends them, as on shitbox.

  ./keys are throwaway keys for this test alone.
*/
{ mkTest }:
mkTest (
  { systems, ... }:
  let
    tunnel = {
      box = "10.44.33.3";
      hub = "10.44.33.1";
    };
    wan = {
      box = "192.168.50.2";
      hub = "192.168.50.1";
    };
    key = name: builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ./keys/${name});

    remote =
      { config, pkgs, ... }:
      {
        imports = [
          ../../modules/nixos/initrd-wifi.nix
          ../../modules/nixos/initrd-wireguard.nix
        ];

        boot.initrd.network = {
          enable = true;
          ssh = {
            enable = true;
            port = 2222;
            authorizedKeys = [ (key "client.pub") ];
            # A guest path: initrd-ssh makes each one an attribute name, which
            # may not refer to the store. The running system provides it,
            # because the bootloader install reads it before `gated` is active.
            hostKeys = [ "/etc/initrd-host-key" ];
          };
        };
        boot.initrd.systemd = {
          users.root.shell = "/bin/systemd-tty-ask-password-agent";
          network.networks = {
            "10-wan" = {
              matchConfig.Name = "wan";
              address = [ "${wan.box}/24" ];
            };
            # Static, not DHCP: both radios are in one network namespace, where
            # networkd's DHCP server and client did not reach each other.
            # shitbox takes its lease from a real router.
            "10-wifi" = {
              matchConfig.Name = "wlan0";
              address = [ "10.99.0.2/24" ];
            };
            "10-ap" = {
              matchConfig.Name = "wlan1";
              address = [ "10.99.0.1/24" ];
            };
          };
          contents."/etc/hostapd.conf".text = ''
            interface=wlan1
            driver=nl80211
            ssid=initrd-test
            hw_mode=g
            channel=1
            wpa=2
            wpa_key_mgmt=WPA-PSK
            rsn_pairwise=CCMP
            wpa_passphrase=initrd-test-passphrase
          '';
          storePaths = [ "${pkgs.hostapd}/bin/hostapd" ];
          services.initrd-test-ap = {
            wantedBy = [ "initrd.target" ];
            bindsTo = [ "sys-subsystem-net-devices-wlan1.device" ];
            after = [ "sys-subsystem-net-devices-wlan1.device" ];
            conflicts = [ "initrd-switch-root.target" ];
            before = [ "initrd-switch-root.target" ];
            unitConfig.DefaultDependencies = false;
            serviceConfig.ExecStart = "${pkgs.hostapd}/bin/hostapd /etc/hostapd.conf";
          };
          services.unlock-gate = {
            description = "Wait for a password from a remote caller";
            requiredBy = [ "initrd.target" ];
            before = [ "initrd.target" ];
            unitConfig.DefaultDependencies = false;
            serviceConfig = {
              Type = "oneshot";
              # Gives the WiFi time to associate before the prompt. A failure
              # is ignored so the boot reaches stage 2, whose journal holds the
              # initrd's and tells the test what happened.
              ExecStartPre = "-${config.boot.initrd.systemd.package}/lib/systemd/systemd-networkd-wait-online --interface=wlan0 --timeout=60";
              ExecStart = "/bin/systemd-ask-password --timeout=0 unlock-gate";
              # /run survives into stage 2, where the test reads it.
              StandardOutput = "file:/run/unlock-gate";
            };
          };
        };
        boot.initrd.kernelModules = [ "mac80211_hwsim" ];

        boot.initrd.wifi = {
          enable = true;
          interface = "wlan0";
          kernelModules = [ ];
          configFile = "${pkgs.writeText "wpa_supplicant.conf" ''
            network={
              ssid="initrd-test"
              psk="initrd-test-passphrase"
            }
          ''}";
        };
        boot.initrd.wireguard = {
          enable = true;
          privateKeyFile = "${./keys/wg-box.key}";
          address = [ "${tunnel.box}/24" ];
          peers = [
            {
              PublicKey = key "wg-hub.pub";
              Endpoint = "${wan.hub}:51820";
              AllowedIPs = [ "${tunnel.hub}/32" ];
              PersistentKeepalive = 25;
            }
          ];
        };
      };
  in
  {
    name = "initrd-remote";
    backend = "qemu";
    phases.test = {
      script = ../initrd-remote.py;
      after = [ "boot" ];
    };
    settings.gated = "${(systems.box.extendModules { modules = [ remote ]; }).config.system.build.toplevel}";

    nodes.box =
      { settings, ... }:
      {
        vivarium.efi = true;
        vivarium.lateClosure = [ settings.gated ];
        environment.etc.initrd-host-key = {
          source = ./keys/initrd-host;
          mode = "0600";
        };
        vivarium.interfaces.wan = {
          segment = "wan";
          addresses = [ "${wan.box}/24" ];
        };
      };

    nodes.hub = {
      vivarium.interfaces.wan = {
        segment = "wan";
        addresses = [ "${wan.hub}/24" ];
      };
      networking.wireguard.interfaces.wg0 = {
        ips = [ "${tunnel.hub}/24" ];
        listenPort = 51820;
        privateKeyFile = "${./keys/wg-hub.key}";
        peers = [
          {
            publicKey = key "wg-box.pub";
            allowedIPs = [ "${tunnel.box}/32" ];
          }
        ];
      };
      environment.etc.test-client = {
        source = ./keys/client;
        mode = "0600";
      };
    };
  }
)
