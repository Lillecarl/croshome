{ pkgs, ... }:
let
  # Homebrew 6 refuses to load a cask from a tap nobody has vouched for, and
  # `brew bundle` failing takes the whole activation with it. The tap named
  # here is the one ./fuse.nix adds; `brew trust` writes exactly this file.
  brewTrust = pkgs.writeText "homebrew-trust.json" (
    builtins.toJSON { trustedtaps = [ "macos-fuse-t/cask" ]; }
  );
in
{
  imports = [ ../../home ];

  home.username = "lillecarl";
  home.homeDirectory = "/Users/lillecarl";
  home.stateVersion = "26.11";

  # Both locations, because brew picks between them from the environment: it
  # uses $XDG_CONFIG_HOME/homebrew when that is set, which is the case in a
  # shell, and ~/.homebrew otherwise -- and activation runs brew under sudo,
  # which resets the environment down to PATH.
  home.file.".homebrew/trust.json".source = brewTrust;
  xdg.configFile."homebrew/trust.json".source = brewTrust;

  # See ../../modules/home/agent-machine.nix -- the machine section every harness
  # reads. Only the values that differ per machine live here.
  programs.agentMachine = {
    hostName = "macbook";
    cloneDir = "~/Dynamist";
  };

  home.packages = [
    pkgs.autossh
  ];

  # Apple's OpenSSH is built without FIDO, so neither its ssh-keygen nor its
  # agent can use the YubiKey's ed25519-sk key ("No FIDO SecurityKeyProvider
  # specified"). Nixpkgs' OpenSSH has it built in: its client, and its agent
  # as a launchd agent in place of Apple's. Apple's Keychain integration for
  # passphrases (UseKeychain) goes with it.
  programs.ssh.package = pkgs.openssh;
  services.ssh-agent.enable = true;

  # touchgate on dynhetz signs a request through this agent, with a touch.
  # Every key in the agent reaches dynhetz this way; only the sk key needs
  # the touch.
  programs.ssh.settings."dynhetz dynhetz.ch.se.eu.org 37.27.129.237".ForwardAgent = true;
}
