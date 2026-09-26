{ ... }:
{
  # A system-wide service and socket, not the per-user units the module
  # defaults to. The socket is /run/pipewire/pipewire-0, and the "pipewire"
  # group is the whole of its access control: every member connects to the
  # one server at once, which per-user units cannot give.
  #
  # Upstream calls systemWide not recommended. It is asked for here on
  # purpose, for that shared socket.
  services.pipewire = {
    enable = true;
    systemWide = true;

    # Pulse, and not ALSA or JACK. Pulse is the one client protocol this
    # host serves; the other two are separate protocol modules a client does
    # not need to reach the graph. This is also what raises
    # services.pipewire.audio.enable, so WirePlumber handles audio.
    pulse.enable = true;
  };

  # Membership is what grants a connection to the socket above, so the login
  # user is added to the group. The module also puts @pipewire in
  # security.pam.loginLimits, so the group gets realtime priority without
  # rtkit.
  users.users.lillecarl.extraGroups = [ "pipewire" ];
}
