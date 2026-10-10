# A QEMU runner with Venus (guest Vulkan over virtio-gpu) on an Apple
# silicon host: guest Mesa venus -> virtio-gpu -> virglrenderer -> MoltenVK
# -> Metal.
#
# Upstream QEMU and virglrenderer lack the macOS host side of Venus, so both
# come from UTM's forks, at the revisions UTM itself pins in
# https://github.com/utmapp/UTM/blob/main/patches/sources.
#
#   nix build --file hosts/macbook/venus-vm run && ./result/bin/venus-vm
{
  pkgs ? import /etc/nixpkgs { system = "aarch64-darwin"; },
}:
let
  inherit (pkgs) lib;
  hostPkgs = pkgs;

  # UTM's QEMU includes epoxy/egl.h whenever OpenGL is on; ANGLE supplies
  # the EGL headers here and libEGL at runtime. It ships only angle.pc, and
  # libepoxy asks pkg-config for `egl`.
  angleEgl = pkgs.writeTextDir "lib/pkgconfig/egl.pc" ''
    Name: egl
    Description: EGL from ANGLE
    Version: ${pkgs.angle.version}
    Libs: -L${pkgs.angle}/lib -lEGL
    Cflags: -I${pkgs.angle}/include
  '';

  # Upstream libepoxy hard-codes PLATFORM_HAS_EGL 0 on __APPLE__.
  libepoxy = pkgs.libepoxy.overrideAttrs (old: {
    src = pkgs.fetchFromGitHub {
      owner = "utmapp";
      repo = "libepoxy";
      rev = "bf98587477fe68d07b93319ece7b40a7d0e2eabe";
      hash = "sha256-S+tcnL0UojdU4U3qqMQOiOwO8/6Ic2ghI3YUcUUK7DM=";
    };
    # epoxy/egl.h includes EGL/eglplatform.h, but neither UTM's meson nor
    # epoxy.pc passes the egl include path on: UTM builds into one shared
    # prefix. Propagating ANGLE puts its include/ on every consumer's path.
    propagatedBuildInputs = old.propagatedBuildInputs or [ ] ++ [
      angleEgl
      pkgs.angle
    ];
    # UTM bundles ANGLE as frameworks inside its app; point at the dylibs.
    postPatch = old.postPatch or "" + ''
      substituteInPlace src/dispatch_common.c \
        --replace-fail '"EGL.framework/Versions/Current/EGL"' '"${pkgs.angle}/lib/libEGL.dylib"' \
        --replace-fail '"GLESv1_CM.framework/Versions/Current/GLESv1_CM"' '"${pkgs.angle}/lib/libGLESv1_CM.dylib"' \
        --replace-fail '"GLESv2.framework/Versions/Current/GLESv2"' '"${pkgs.angle}/lib/libGLESv2.dylib"'
    '';
    mesonFlags = map (
      flag: if flag == "-Degl=no" then "-Degl=yes" else flag
    ) old.mesonFlags;
  });

  virglrenderer =
    (pkgs.virglrenderer.override {
      inherit libepoxy;
      vulkanSupport = true;
      nativeContextSupport = false;
    }).overrideAttrs
      (old: {
        version = "1.3.0-utm";
        src = pkgs.fetchFromGitHub {
          owner = "utmapp";
          repo = "virglrenderer";
          rev = "5d26f605f50f8e22002ec6db5fb775e1992d4e96";
          hash = "sha256-LYIbB2AUA9LZPA8hE0ZXnScoQkaPJMss5ZqOWUXcPig=";
        };
        patches = [ ];
        mesonFlags = old.mesonFlags ++ [
          (lib.mesonBool "tests" false)
          (lib.mesonBool "check-gl-errors" false)
          (lib.mesonOption "render-server-mode" "process")
        ];
      });

  qemu =
    (pkgs.qemu.override {
      inherit libepoxy virglrenderer;
      hostCpuTargets = [ "aarch64-softmmu" ];
      openGLSupport = true;
      virglSupport = true;
      rutabagaSupport = false;
      guestAgentSupport = false;
      # openGLSupport pulls these in unconditionally; both are Linux-only.
      libgbm = null;
      libdrm = null;
    }).overrideAttrs
      (old: {
        version = "10.0.12-utm";
        src = pkgs.fetchurl {
          url = "https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/qemu-10.0.12-utm.tar.xz";
          hash = "sha256-fJYFKQs0FS3ruELpZaVdLk+7pHk+U2q2d7QCfl3Auho=";
        };
        patches =
          lib.filter (p: lib.elem (baseNameOf p) [ "skip-macos-icon.patch" ]) old.patches
          ++ [
            (pkgs.fetchurl {
              url = "https://raw.githubusercontent.com/utmapp/UTM/7eadb056ae0f91d979059544d0ddcd2d5a40be92/patches/qemu-10.0.12-utm.patch";
              hash = "sha256-BaRtXlL9Zi6NQL0o0jwM9wL5LMKKg+yonp7hTBZGruc=";
            })
            # Offer VIRTIO_GPU_F_BLOB_ALIGNMENT (Linux 7.2) at the host page
            # size, as libkrun does. Without it the guest places Venus's
            # ring blob 4K-aligned and QEMU aborts on its first access.
            ./qemu-blob-alignment.patch
          ];
      });

  guest = import "${pkgs.path}/nixos" {
    system = "aarch64-linux";
    configuration =
      { modulesPath, pkgs, ... }:
      {
        imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

        system.stateVersion = "26.11";
        networking.hostName = "venus";

        # Linux 7.2 is the first with VIRTIO_GPU_F_BLOB_ALIGNMENT, which
        # ./qemu-blob-alignment.patch offers.
        boot.kernelPackages = pkgs.linuxPackages_latest;

        hardware.graphics.enable = true;
        # Linux 7.2 rejects blob sizes that are not multiples of the
        # negotiated blob alignment, and Mesa 26.2.2's Venus does not round
        # them up. Without this vkCreateInstance fails with OUT_OF_HOST_MEMORY.
        hardware.graphics.package = pkgs.mesa.overrideAttrs (old: {
          patches = old.patches or [ ] ++ [
            (pkgs.fetchpatch {
              name = "venus-honor-blob-alignment.patch";
              url = "https://gitlab.freedesktop.org/mesa/mesa/-/commit/4cf0989083d25b92d02c6fef2bed934ad77b4ecd.patch";
              hash = "sha256-MYbhodTaJBnPQplr5xGz94QWv4zBdj1bnfRWSc2Kysk=";
            })
          ];
        });
        environment.systemPackages = [
          pkgs.vulkan-tools
          pkgs.mesa-demos
        ];

        services.getty.autologinUser = "root";

        virtualisation = {
          host.pkgs = hostPkgs;
          qemu.package = qemu;
          memorySize = 8192;
          cores = 8;
          diskImage = null;
          graphics = true;
          sharedDirectories.out = {
            source = "$VENUS_OUT";
            target = "/out";
          };
          qemu.options = [
            "-device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=4G"
            "-display cocoa,gl=core"
          ];
        };

        systemd.services.venus-probe = {
          wantedBy = [ "multi-user.target" ];
          after = [ "multi-user.target" ];
          path = [
            pkgs.vulkan-tools
            pkgs.util-linux
          ];
          serviceConfig.Type = "oneshot";
          script = ''
            {
              dmesg | grep -E '\[drm\]' || true
              vulkaninfo --summary
            } > /out/vulkaninfo.txt 2>&1 || true
            vulkaninfo > /out/vulkaninfo-full.txt 2>&1 || true
            if [ ! -e /out/keep ]; then systemctl poweroff; fi
          '';
        };
      };
  };
  # qemu-common pins `virt-11.0` for darwin hosts; UTM's fork is QEMU 10.0.
  vm = pkgs.runCommand "venus-vm-script" { } ''
    mkdir -p $out/bin
    substitute ${guest.config.system.build.vm}/bin/run-venus-vm $out/bin/run-venus-vm \
      --replace-fail "-machine virt-11.0," "-machine virt-10.0,"
    chmod +x $out/bin/run-venus-vm
  '';

  run = pkgs.writeShellApplication {
    name = "venus-vm";
    text = ''
      export VENUS_OUT=''${VENUS_OUT:-$PWD/venus-out}
      mkdir -p "$VENUS_OUT"
      export VK_DRIVER_FILES=${pkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json
      export TMPDIR=''${TMPDIR:-/tmp}
      exec ${vm}/bin/run-venus-vm "$@"
    '';
  };
in
{
  inherit
    libepoxy
    virglrenderer
    qemu
    guest
    vm
    run
    ;
}
