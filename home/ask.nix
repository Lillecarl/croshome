{ pkgs, ... }:
let
  # `writePython3Bin` and not a shebang. `#!/usr/bin/env python3` looked fine
  # from an agent's shell, where Claude Code leaks a store python onto PATH,
  # and would have failed for a person: nothing in this configuration installs
  # python3 into the system path or the user profile. The writer pins the
  # interpreter in the shebang, so these run wherever they are, with no
  # dependency on what happens to be on PATH.
  #
  # These two were in ./localbin at first, for the property that an
  # out-of-store symlink applies without a rebuild. That was the wrong trade
  # once the interpreter turned out to be missing: a script that needs a
  # rebuild beats one that does not run.
  #
  # stdlib only, so `libraries` stays empty. That is deliberate for a program
  # whose job is to hold a passphrase for a moment.
  writer =
    name: source:
    pkgs.writers.writePython3Bin name {
      libraries = [ ];
      # Line length only. Everything else flake8 says about these files is
      # worth hearing, so the list stays this short.
      flakeIgnore = [ "E501" ];
    } (builtins.readFile source);
in
{
  # `ask` and `answer`: how an agent gets a secret it must not read.
  #
  # An agent has no terminal, so anything that prompts fails -- pinentry with
  # "Inappropriate ioctl for device", and every `--passphrase-fd` still needs
  # the value from somewhere. `ask` blocks on a socket, a person runs `answer`
  # in their own terminal, and the value comes out of ask's stdout into the
  # command that needs it.
  #
  # See the docstring in ./ask/ask.py for what that is worth and what it is
  # not: it keeps a credential out of the transcript, which is where they
  # leak. It is not a boundary against the agent.
  home.packages = [
    (writer "ask" ./ask/ask.py)
    (writer "answer" ./ask/answer.py)
  ];
}
