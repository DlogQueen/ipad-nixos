{ pkgs, ... }:

{
  # iPad RE workstation tools
  packages = with pkgs; [
    # iOS device communication
    libimobiledevice  # ideviceinfo, idevicepair, idevicesyslog
    libirecovery      # irecovery — recovery/DFU mode USB communication
    usbmuxd           # USB multiplexing daemon for iOS devices
    usbutils          # lsusb for device detection

    # Serial console (for reading boot output over USB)
    picocom           # Lightweight serial terminal
    minicom           # Classic serial terminal

    # Cross-compilation for aarch64 (iPad ARM64)
    dtc               # Device tree compiler
    binutils          # Binary analysis (objdump, readelf, nm)

    # Reverse engineering tools
    ghidra            # NSA reverse engineering framework (free, Java-based)
    radare2           # CLI reverse engineering toolkit
    python3           # Many RE scripts are Python

    # Build tools
    gnumake
    cmake
    pkg-config
    git

    # Research tools
    jq                # JSON processing (for API/device tree analysis)
    curl
    wget
  ];

  # aarch64 cross-compilation via Nix
  # Usage: nix build .#packages.aarch64-linux.kernel (when we get there)

  enterShell = ''
    echo ""
    echo "  iPad NixOS — RE Workstation"
    echo "  Target: iPad Air 2 (A8X, MacBookAir7,2-era hardware)"
    echo ""
    echo "  Tools: libimobiledevice, irecovery, ghidra, radare2"
    echo "  Serial: picocom /dev/ttyACM0 -b 115200"
    echo ""
    echo "  Phase 0: Research & feasibility analysis"
    echo ""
  '';
}
