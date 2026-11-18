# The wireless numpad (MOSART dongle) drives the gaming VM: input routing,
# the controller's USB passthrough, the right monitor's input, brightness
# and volume. Ported from ~/Code/nixos scripts/remapper2.py, with the same
# keys. The numpad itself never goes to the VM, so KP2 always comes back.
let
  key = k: "KEY_${k}";
  bind = k: action: {
    key = key k;
    inherit action;
  };
  hold = k: action: bind k action // { hold = key "KP0"; };
  vcpInput = value: {
    do = "vcp";
    model = "XWU-CBA";
    feature = "0x60";
    inherit value;
  };
in
{
  services.remapper = {
    enable = true;
    settings = {
      # The dongle has several nodes named alike; only one reports the keypad.
      numpad = {
        vendor = "062a";
        product = "4101";
        keys = [ (key "KP0") ];
      };
      domain = "win11-4";
      vmUsb = [
        # 8BitDo: the product id changes with the controller's mode.
        {
          vendor = "2dc8";
          product = "301c";
        }
        {
          vendor = "2dc8";
          product = "310a";
        }
        {
          vendor = "2dc8";
          product = "310c";
        }
      ];
      # Through an evdev input, not USB: they never leave the host, so niri
      # gets them back at once. Every node of each device.
      forward = [
        # K1301FN keyboard.
        {
          vendor = "1c4f";
          product = "0083";
        }
        # Glorious Model D.
        {
          vendor = "258a";
          product = "0033";
        }
      ];
      brightness = {
        primary = "BenQ XL2430T";
        follower = "XWU-CBA";
        offset = 25;
      };
      sound = "/home/lillecarl/Documents/kbnotification.mp3";
      bindings = [
        (bind "KP0" {
          do = "tap";
          key = key "SPACE";
          sound = true;
        })
        (bind "KP1" { do = "guest"; })
        (bind "KP2" { do = "host"; })
        (bind "KP4" (vcpInput "0x11")) # DisplayPort
        (bind "KP5" (vcpInput "0x0f")) # HDMI
        (bind "KPPLUS" {
          do = "volume";
          up = true;
        })
        (bind "KPMINUS" {
          do = "volume";
          up = false;
        })
        (hold "KP1" { do = "vm-start"; })
        (hold "KP2" { do = "vm-stop"; })
        (hold "KPPLUS" {
          do = "brightness";
          delta = 10;
        })
        (hold "KPMINUS" {
          do = "brightness";
          delta = -10;
        })
      ];
    };
  };
}
