{ config, pkgs, ros-pkgs, lib, ... }:

let
  user      = "admin";
  password  = "password";
  hostname  = "68fb735b1ec5a2b67f2650df";  # keep your template if you render it; otherwise set a real name
  repoName  = "polyflow_robot_${hostname}";
  homeDir   = "/home/${user}";
  wsDir     = "${homeDir}/${repoName}/workspace";
in
{
  ################################################################################
  # Hardware / boot
  ################################################################################
  nixpkgs.overlays = [
    (final: super: {
      makeModulesClosure = x: super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  imports = [
    "${builtins.fetchGit {
      url = "https://github.com/NixOS/nixos-hardware.git";
      rev = "26ed7a0d4b8741fe1ef1ee6fa64453ca056ce113";
    }}/raspberry-pi/4"
  ];

  boot = {
    kernelPackages = ros-pkgs.linuxKernel.packages.linux_rpi4;
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  ################################################################################
  # System basics
  ################################################################################
  system.autoUpgrade.flags = [ "--max-jobs" "1" "--cores" "1" ];

  networking = {
    hostName = hostname;
    networkmanager.enable = true;
    nftables.enable = true;
  };

  services.openssh.enable = true;
  services.timesyncd.enable = true;
  services.timesyncd.servers = [ "pool.ntp.org" ];
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "multi-user.target" ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  hardware.enableRedistributableFirmware = true;
  system.stateVersion = "23.11";

  # keep a copy of this file on the target (optional)
  environment.etc."nixos/configuration.nix" = {
    source = ./configuration.nix;
    mode = "0644";
  };

  ################################################################################
  # Users
  ################################################################################
  users.mutableUsers = false;
  users.users.${user} = {
    isNormalUser = true;
    password = password;
    extraGroups = [ "wheel" ];
    home = homeDir;
  };
  security.sudo.wheelNeedsPassword = false;

  ################################################################################
  # Packages
  # - ros2 binary: ros-humble.ros2cli
  # - launch plugin (python): ros-humble.ros2launch
  # - base runtime: ros-humble.ros-base
  ################################################################################
  environment.systemPackages = with ros-pkgs; with rosPackages.humble; [
    pkgs.vim
    pkgs.git
    pkgs.wget
    pkgs.inetutils

    # ROS 2
    ros2cli          # provides /bin/ros2
    ros2launch       # python plugin implementing `ros2 launch`
    ros-base         # (includes core + common tools)

    # Build tools if you really want to colcon at runtime:
    pkgs.python3
    pkgs.colcon      # alias to colcon-common-extensions in many pkgs sets
  ];

  ################################################################################
  # Services (patched)
  ################################################################################

  # 1 Setup: clone/pull + colcon build
  systemd.services.polyflow-setup = {
    description = "Clone/update Polyflow robot repo and colcon build";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "time-sync.target" ];
    wants = [ "network-online.target" "time-sync.target" ];

    path = with pkgs; [ git colcon python3 ros-pkgs.rosPackages.humble.ros2cli ];

    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "users";
      WorkingDirectory = homeDir;
      StateDirectory = "polyflow";
      StandardOutput = "journal";
      StandardError  = "journal";
    };

    script = ''
      set -eo pipefail

      export HOME=${homeDir}

      if [ -d "${homeDir}/${repoName}" ]; then
        echo "[setup] Repo exists; pulling latest…"
        cd "${homeDir}/${repoName}"
        git pull --ff-only
      else
        echo "[setup] Cloning repo…"
        git config --global --unset https.proxy || true
        git clone "https://github.com/drewswinney/${repoName}.git" "${homeDir}/${repoName}"
        chown -R ${user}:users "${homeDir}/${repoName}"
      fi

      echo "[setup] Building with colcon…"
      cd "${wsDir}"
      colcon build
      echo "[setup] Done."
    '';
  };

  # 2 Runtime: run your launch file; temporarily disable nounset when sourcing
  systemd.services.polyflow-webrtc = {
    description = "Run Polyflow WebRTC launch with ros2 launch";
    wantedBy = [ "multi-user.target" ];
    after = [ "polyflow-setup.service" "network-online.target" ];
    wants = [ "polyflow-setup.service" "network-online.target" ];

    # Only need the ros2 binary on PATH
    path = [ ros-pkgs.rosPackages.humble.ros2cli ];

    environment = {
      ROS_DOMAIN_ID = "0";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    serviceConfig = {
      Restart = "always";
      RestartSec = "3s";
      User = user;
      Group = "users";
      WorkingDirectory = wsDir;
      StateDirectory = "polyflow";
      StandardOutput = "journal";
      StandardError  = "journal";
    };

    script = ''
      # keep -e and -o pipefail, but drop global -u to avoid colcon env hook issues
      set -eo pipefail

      if [ -f "${wsDir}/install/setup.sh" ]; then
        echo "[webrtc] Sourcing colcon overlay…"
        # Temporarily allow unset vars; colcon env scripts set/expect these.
        set +u
        . "${wsDir}/install/setup.sh"
        set -u
      else
        echo "[webrtc] No install/setup.sh found; did build succeed?" >&2
        exit 1
      fi

      echo "[webrtc] Launching…"
      exec ros2 launch webrtc launch/webrtc.launch.py
    '';
  };
}
