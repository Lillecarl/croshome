# /etc/systemd/user/sommelier@0.service.d/cros-sommelier-override.conf
[Service]
Environment="SOMMELIER_ACCELERATORS=Super_L,<Alt>bracketleft,<Alt>bracketright,<Alt>tab,<Alt>minus,<Alt>equal,<Alt>space"

# systemctl --user edit cros-garcon.service
[Service]
Environment="PATH=/home/lillecarl/.nix-profile/bin:/home/lillecarl/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games"
Environment="XDG_DATA_DIRS=/nix/var/nix/profiles/default/share:/home/lillecarl/.nix-profile/share:/usr/share/ubuntu:/usr/local/share:/usr/share:/var/lib/snapd/desktop:/home/lillecarl/.local/share:/home/lillecarl/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share:/home/lillecarl/.nix-profile/share:/nix/var/nix/profiles/default/share:/home/lillecarl/.nix-profile/share:/nix/var/nix/profiles/default/share"
