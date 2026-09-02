{ ... }:
{
  # Out of the box this Mac slept after 1 minute idle on battery
  # (`pmset -g custom` showed `sleep 1`), which also drops Wi-Fi with it.
  # `pmset -b` only touches the keys given, so every other Battery Power
  # setting (standby, hibernatemode, disksleep, ...) is untouched.
  #
  # There is no nix-darwin module for pmset, so this runs the binary
  # directly on activation, the same pattern as the HIToolbox/nvram calls
  # in ./eurkey.nix.
  system.activationScripts.postActivation.text = ''
    echo "setting battery power sleep timers..." >&2
    /usr/bin/pmset -b sleep 30 displaysleep 5
  '';
}
