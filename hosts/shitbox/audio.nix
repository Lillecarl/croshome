# Meetings: the headset mic on the Antlion USB adapter, through RNNoise.
# Ported from ~/Code/nixos/hosts/shitbox/audiovideo.nix.
{ pkgs, ... }:
let
  webcamCard = "alsa_card.usb-046d_HD_Pro_Webcam_C920_6B10B2DF-02";
  headsetMic = "alsa_input.usb-Antlion_Audio_Antlion_USB_adapter_20180707-00.mono-fallback";
in
{
  # The C920's mic sits across the desk and hears the room; the headset mic
  # is the one to use. Off, so nothing picks it by default. The camera itself
  # is a separate v4l2 device and stays.
  services.pipewire.wireplumber.extraConfig.disable-webcam-mic."monitor.alsa.rules" = [
    {
      matches = [ { "device.name" = webcamCard; } ];
      actions.update-props."device.disabled" = true;
    }
  ];

  # A virtual source, "Noise Canceling source", that reads the headset mic
  # and passes it through RNNoise. Pick it in Slack. Its high
  # priority.session makes it the default source wherever no default was
  # chosen by hand.
  services.pipewire.extraConfig.pipewire."90-rnnoise"."context.modules" = [
    {
      name = "libpipewire-module-filter-chain";
      args = {
        "node.description" = "Noise Canceling source";
        "media.name" = "Noise Canceling source";
        "filter.graph".nodes = [
          {
            type = "ladspa";
            name = "rnnoise";
            plugin = "${pkgs.rnnoise-plugin}/lib/ladspa/librnnoise_ladspa.so";
            label = "noise_suppressor_mono";
            control = {
              "VAD Threshold (%)" = 75.0;
              "VAD Grace Period (ms)" = 200;
              "Retroactive VAD Grace (ms)" = 50;
            };
          }
        ];
        "capture.props" = {
          "node.name" = "capture.rnnoise_source";
          # Pinned, not the default source: the default is this filter's own
          # output, so following it would loop.
          "target.object" = headsetMic;
          "node.passive" = true;
          "audio.rate" = 48000;
        };
        "playback.props" = {
          "node.name" = "rnnoise_source";
          "media.class" = "Audio/Source";
          "audio.rate" = 48000;
          "priority.session" = 2000;
        };
      };
    }
  ];
}
