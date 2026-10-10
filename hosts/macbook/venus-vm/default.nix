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
    mesonFlags = map (flag: if flag == "-Degl=no" then "-Degl=yes" else flag) old.mesonFlags;
  });

  # UTM's MoltenVK adds robustness2 (zink needs nullDescriptor), geometry
  # shaders, and host pointer imports into non-host-visible memory types,
  # which its virglrenderer pin relies on. It needs UTM's SPIRV-Cross.
  spirv-cross = pkgs.spirv-cross.overrideAttrs {
    version = "1.4.357.0-utm";
    src = pkgs.fetchFromGitHub {
      owner = "utmapp";
      repo = "SPIRV-Cross";
      rev = "939b40b33a44443c404c4078823c406e3c94866f";
      hash = "sha256-YeiKovpy41nXCn0jbMbTi0Y/3VxUitFrDaHfyxGsQEU=";
    };
  };

  moltenvk =
    (pkgs.moltenvk.override {
      inherit spirv-cross;
      # UTM builds without it, and the fork's mesh pipeline path sets the
      # private properties on MTLMeshRenderPipelineDescriptor, which lacks them.
      enablePrivateAPIUsage = false;
    }).overrideAttrs
      (old: {
        version = "1.4.2-utm";
        src = pkgs.fetchFromGitHub {
          owner = "utmapp";
          repo = "MoltenVK";
          rev = "05604465d691118cfd20f53a48ecf1aad9c12f93";
          hash = "sha256-fVIJ7kihxxmQ8eEiIEHsAFUe/JiEQ4p4xkxYw2WuJMU=";
        };
        # nixpkgs renames the SPIRV-Cross namespace; the fork spells it once.
        postPatch = old.postPatch + ''
          substituteInPlace MoltenVK/MoltenVK/GPUObjects/MVKPipeline.mm \
            --replace-fail "MVK_spirv_cross::" "spirv_cross::"
        '';
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
        patches = lib.filter (p: lib.elem (baseNameOf p) [ "skip-macos-icon.patch" ]) old.patches ++ [
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
            # gl=es: EGL through ANGLE. virglrenderer imports a Venus blob
            # into GL (a Vulkan client presenting to the compositor) only on
            # EGL; on CGL (gl=core) the compositor's context dies with
            # EINVAL on PIPE_RESOURCE_SET_TYPE.
            "-display cocoa,gl=es"
          ];
        };

        programs.niri.enable = true;

        # Root, so the test writes to the 9p share without an ownership map.
        # greetd refuses to start without default_session, even when
        # initial_session is the only session that ever runs.
        services.greetd =
          let
            session = {
              user = "root";
              command = "${lib.getExe pkgs.niri} --config ${niriConfig pkgs}";
            };
          in
          {
            enable = true;
            settings.initial_session = session;
            settings.default_session = session;
          };

        # The console is the graphical tty, so a session that never comes up
        # leaves no trace on the host without this.
        systemd.services.venus-journal = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.Type = "oneshot";
          script = ''
            sleep 90
            journalctl -b --no-pager > /out/journal.txt 2>&1
            if [ ! -e /out/keep ]; then systemctl poweroff; fi
          '';
        };
      };
  };

  niriConfig =
    pkgs:
    pkgs.writeText "niri-venus.kdl" ''
      hotkey-overlay {
          skip-at-startup
      }
      spawn-at-startup "${lib.getExe (desktopTest pkgs)}"
    '';

  # Runs inside niri. Writes /out and powers off, unless /out/keep exists.
  desktopTest =
    pkgs:
    pkgs.writeShellApplication {
      name = "venus-desktop-test";
      runtimeInputs = [
        pkgs.bc
        pkgs.coreutils
        pkgs.grim
        pkgs.mesa-demos
        pkgs.systemd
        pkgs.util-linux
        pkgs.vulkan-tools
      ];
      text = ''
        exec > /out/desktop-test.txt 2>&1
        set +e
        dmesg | grep -E '\[drm\]'
        vulkaninfo --summary
        vulkaninfo > /out/vulkaninfo-full.txt 2>&1

        echo "== eglinfo, default GL driver"
        eglinfo -B -p wayland
        echo "== eglinfo, zink"
        MESA_LOADER_DRIVER_OVERRIDE=zink eglinfo -B -p wayland

        echo "== vkcube, 1000 frames"
        start=$(date +%s.%N)
        MESA_LOG=stderr VN_DEBUG=wsi,result vkcube --wsi wayland --c 1000 &
        cube=$!
        sleep 3
        grim /out/vkcube.png
        wait "$cube"
        echo "vkcube rc=$? seconds=$(echo "$(date +%s.%N) - $start" | bc)"
        coredumpctl info --no-pager vkcube

        for driver in default zink; do
          echo "== es2gears_wayland, $driver"
          if [ "$driver" = zink ]; then export MESA_LOADER_DRIVER_OVERRIDE=zink; fi
          # Line-buffered, or timeout's SIGTERM drops the FPS lines.
          timeout 16 stdbuf -oL es2gears_wayland &
          gears=$!
          sleep 8
          grim "/out/es2gears-$driver.png"
          wait "$gears"
          unset MESA_LOADER_DRIVER_OVERRIDE
        done

        if [ ! -e /out/keep ]; then systemctl poweroff; fi
      '';
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
      export VK_DRIVER_FILES=${moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json
      # virglrenderer wraps Venus blobs as MTLTextures through ANGLE's Metal
      # device, which exists only on ANGLE's Metal backend; WebKit's ANGLE
      # (what UTM ships) defaults to it, nixpkgs' does not.
      export ANGLE_DEFAULT_PLATFORM=metal
      export TMPDIR=''${TMPDIR:-/tmp}
      exec ${vm}/bin/run-venus-vm "$@"
    '';
  };
in
{
  inherit
    libepoxy
    moltenvk
    spirv-cross
    virglrenderer
    qemu
    guest
    vm
    run
    ;
}
