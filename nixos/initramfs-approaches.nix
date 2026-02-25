# Five approaches to building an initramfs in nixpkgs
#
# This file is documentation-as-code.  None of these are importable as-is;
# they are annotated expressions showing each option's tradeoffs.
# The actual build target is ./initramfs.nix (Approach 2, makeInitrdNG).
#
# Summary table:
#
#  Approach             | Compressed | Uncompressed | Cross OK | Init type  | Complexity
#  ---------------------|------------|--------------|----------|------------|-----------
#  1. makeInitrd        | ~15 MB     | ~50 MB       | yes      | shell/any  | low
#  2. makeInitrdNG      | ~12 MB     | ~45 MB       | yes      | shell/any  | low
#  3. NixOS initialRamdisk | ~80 MB  | ~250 MB      | limited  | stage-1    | high
#  4. Raw cpio          | ~10 MB     | ~35 MB       | yes      | shell/any  | medium
#  5. Alpine/pmOS style | ~6 MB      | ~20 MB       | yes      | busybox    | medium
#
# Recommendation: Approach 2 (makeInitrdNG) for this project.
# Rationale: correct ELF dependency walking, reproducible, Nix-native,
#            works with cross-compilation, smaller than approach 3.

# =============================================================================
# APPROACH 1: pkgs.makeInitrd  (the classic builder)
# =============================================================================
#
# Source: pkgs/build-support/kernel/make-initrd.nix
#         pkgs/build-support/kernel/make-initrd.sh
#
# How it works:
#   1. Takes a list of { object = <storePath>; symlink = "/target/path"; }
#   2. Runs closureInfo on all objects to get the full Nix closure
#   3. Copies the entire closure into a staging dir under their /nix/store/... paths
#   4. Creates symlinks at the specified target paths pointing into the store
#   5. Packs everything with `cpio -H newc` and compresses
#
# The resulting cpio has:
#   /nix/store/<hash>-busybox/bin/busybox  ← actual binary
#   /bin                                    ← symlink → /nix/store/.../bin
#   /init                                   ← symlink → /nix/store/.../init-script
#
# Limitation vs makeInitrdNG: does NOT walk ELF dependencies.  If you include
# a dynamically-linked binary (like dropbear against glibc), you must also
# explicitly add its libc and libz to `contents`.  With a static busybox this
# is not a problem.
#
# The `suffix` field (optional) appends a path fragment:
#   { object = dropbear; symlink = "/bin"; suffix = "/bin"; }
# copies dropbear's /bin/ directory to /bin in the cpio.

{ pkgsCrossMusl }:
let
  pkgs = pkgsCrossMusl;
  staticBusybox = pkgs.busybox.override { enableStatic = true; };
  initScript = pkgs.writeScript "init" ''
    #!/bin/ash
    export PATH=/bin:/sbin
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
    mount -t tmpfs tmpfs /tmp
    exec /bin/ash
  '';
in
pkgs.makeInitrd {
  compressor = "zstd";   # or "gzip", "xz", "lzma", "lz4", "cat" (uncompressed)
  # compressorArgs = [ "-19" ];   # override defaults (zstd default is -10)

  # The `prepend` field accepts a list of uncompressed cpio archives to
  # concatenate before the main archive.  Useful for early microcode blobs.
  # prepend = [ "${pkgs.microcode-intel}/initrd" ];

  contents = [
    {
      object = initScript;          # Nix store path (file or directory)
      symlink = "/init";            # Absolute path in the cpio root
      # suffix = "";                # Optional: appended to object path
    }
    {
      # Placing the busybox bin/ tree at /bin means /bin/ash, /bin/mount, etc.
      # all exist.  The kernel resolves the shebang #!/bin/ash via /bin.
      object = "${staticBusybox}/bin";
      symlink = "/bin";
    }
    {
      object = "${staticBusybox}/sbin";
      symlink = "/sbin";
    }
    # For dynamically-linked binaries: add the object AND its libc:
    # {
    #   object = "${pkgs.dropbear}/bin/dropbear";
    #   symlink = "/bin/dropbear";
    # }
    # makeInitrd does NOT auto-copy libc, so you'd also need:
    # {
    #   object = "${pkgs.musl}";
    #   symlink = "/lib/musl";
    # }
    # That's why makeInitrdNG is preferred for non-static binaries.
  ];
}

# =============================================================================
# APPROACH 2: pkgs.makeInitrdNG  (recommended — what initramfs.nix uses)
# =============================================================================
#
# Source: pkgs/build-support/kernel/make-initrd-ng.nix
#         pkgs/build-support/kernel/make-initrd-ng/src/main.rs  (Rust tool)
#
# How it works (key differences from makeInitrd):
#   1. Takes { source = <storePath>; target = "/target/path"; }
#      Note the field names: `source`/`target`, not `object`/`symlink`.
#   2. The Rust tool (make-initrd-ng) walks ELF NEEDED entries via goblin
#      and also handles .note.dlopen sections.  All transitive shared library
#      dependencies are automatically included.
#   3. The staging tree uses the real /nix/store/... paths, so ELF interpreters
#      (the PT_INTERP entry like /nix/store/<hash>-musl/lib/ld-musl-aarch64.so.1)
#      resolve correctly at runtime without any patchelf.
#   4. Pre-creates /run, /tmp, /var/empty in the cpio.
#   5. Produces a reproducible cpio (timestamps normalized to @1, sorted).
#
# The `target` field creates a symlink in the cpio root:
#   source = "${busybox}/bin"  →  copies /nix/store/.../busybox/bin/ recursively
#   target = "/bin"            →  creates /bin → /nix/store/.../busybox/bin

# See ./initramfs.nix for the full working expression.

# =============================================================================
# APPROACH 3: NixOS system.build.initialRamdisk
# =============================================================================
#
# How it works:
#   Build a minimal NixOS configuration for aarch64-linux.
#   NixOS's stage-1 module (nixos/modules/system/boot/stage-1.nix) generates
#   the initramfs automatically, including:
#     - extraUtils (busybox + util-linux + kmod + udev, patchelf'd into a single dir)
#     - stage-1-init.sh (mounts rootfs, starts stage 2)
#     - kernel modules closure
#
# Pros:
#   - Gets you a "real" NixOS with all the niceties
#   - boot.initrd.network.ssh.enable gives you dropbear for free
#   - Handles module loading, udev rules automatically
#
# Cons:
#   - Much larger (~80 MB compressed) — udev, util-linux, many modules
#   - Expects to mount a rootfs and pivot_root — needs modification for
#     a RAM-only system (set fileSystems = {}; boot.initrd.postMountCommands)
#   - Cross-compilation of a full NixOS config is more complex:
#     needs nixpkgs.crossSystem in the nixosSystem call
#   - stage-1-init.sh is not designed for "the initramfs IS the final root"

{ nixpkgs, buildSystem }:
let
  # NixOS minimal config for iPad — generates system.build.initialRamdisk
  ipadNixOS = nixpkgs.lib.nixosSystem {
    # Cross-compile for aarch64; the modules run on the iPad
    system = "aarch64-linux";  # This is the *host* system for nixosSystem

    # For true cross-compilation (building on x86_64):
    # nixpkgs.crossSystem is set to aarch64-linux and
    # nixpkgs.buildPlatform to x86_64-linux.
    modules = [
      ({ config, pkgs, lib, ... }: {
        # Cross-compilation support
        nixpkgs.buildPlatform.system = buildSystem;  # x86_64-linux
        nixpkgs.hostPlatform.system  = "aarch64-linux";

        # Tell NixOS we're RAM-only: no rootfs to mount
        # stage-1 will try to find a root device; we disable that.
        boot.initrd.kernelModules = [
          "g_ether"     # USB gadget Ethernet
        ];
        boot.initrd.availableKernelModules = [];

        # SSH in initrd (uses openssh, not dropbear, in modern NixOS)
        boot.initrd.network.enable = true;
        boot.initrd.network.ssh = {
          enable = true;
          port = 22;
          # authorizedKeys = [ "ssh-ed25519 AAAA..." ];
          # hostKeys = [ /etc/secrets/initrd/ssh_host_ed25519_key ];
        };

        # Run a shell instead of stage 2 for RAM-only operation.
        # This replaces the "switch_root to real rootfs" step.
        boot.initrd.postMountCommands = ''
          # Don't pivot_root — we ARE the root.
          # This hook runs after stage-1's device mounting; since we have
          # no real devices (no fileSystems entries), it runs immediately.
          exec setsid ash -c "exec ash < /dev/tty1 > /dev/tty1 2>&1"
        '';

        # No filesystem entries — no NAND access
        fileSystems = lib.mkForce {};
        swapDevices = lib.mkForce [];

        # The initrd compressor
        boot.initrd.compressor = "zstd";

        system.stateVersion = "25.05";
      })
    ];
  };
in
# The output you want:
ipadNixOS.config.system.build.initialRamdisk
# To get the kernel too: ipadNixOS.config.system.build.kernel

# =============================================================================
# APPROACH 4: Raw cpio via stdenv.mkDerivation
# =============================================================================
#
# How it works:
#   Build a staging directory by hand in a shell derivation, then run
#   `find . | cpio -H newc -o | zstd` yourself.
#   Gives you full control over the cpio layout.
#
# The main challenge: getting dynamically-linked binaries to work.
# You must either:
#   a) Use static binaries (busybox --enable-static), OR
#   b) Copy shared libs and patch the ELF interpreter with patchelf, OR
#   c) Build against musl and copy musl.so explicitly
#
# This is essentially what NixOS's extraUtils does in stage-1.nix (option b):
#   copy_bin_and_libs() — copies the binary + all .so's from ldd output
#   patchelf --set-interpreter $out/lib/ld*.so.? --set-rpath $out/lib $bin

{ pkgsCrossMusl, pkgsBuildHost }:
let
  pkgs = pkgsCrossMusl;
  staticBusybox = pkgs.busybox.override { enableStatic = true; };
  staticDropbear = pkgs.dropbear.override {
    # dropbear doesn't have a simple static override; use musl + link flags
  };
in
pkgs.stdenvNoCC.mkDerivation {
  name = "ipad-initramfs-raw";

  nativeBuildInputs = [
    pkgsBuildHost.cpio
    pkgsBuildHost.zstd
    pkgsBuildHost.findutils
    pkgsBuildHost.bash
  ];

  buildCommand = ''
    # Build staging tree
    mkdir -p root/{bin,sbin,usr/bin,usr/sbin,dev,proc,sys,tmp,run,etc,var/log,root}
    mkdir -p root/var/{empty,run}
    chmod 700 root/root

    # BusyBox — static, just copy the binary and create applet symlinks
    cp ${staticBusybox}/bin/busybox root/bin/busybox
    chmod +x root/bin/busybox

    # Create all BusyBox applet symlinks
    for APPLET in $(${staticBusybox}/bin/busybox --list); do
      case "$APPLET" in
        # sbin applets
        ifconfig|route|mdev|hwclock|sysctl|modprobe|insmod|rmmod)
          ln -sf /bin/busybox root/sbin/$APPLET ;;
        *)
          ln -sf /bin/busybox root/bin/$APPLET ;;
      esac
    done

    # /bin/sh → ash
    ln -sf /bin/busybox root/bin/sh
    ln -sf /bin/busybox root/bin/ash

    # Write /init
    cat > root/init << 'INITEOF'
    #!/bin/sh
    export PATH=/bin:/sbin
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
    mount -t tmpfs tmpfs /tmp
    mount -t tmpfs tmpfs /run
    hostname ipad-nixos
    exec /bin/ash
    INITEOF
    chmod +x root/init

    # Pack the cpio
    mkdir -p $out
    (cd root
     find . -print0 \
       | sort -z \
       | cpio --quiet -o -H newc -R +0:+0 --reproducible --null \
       | zstd -10 > $out/initrd.zst)
    ln -s initrd.zst $out/initrd
  '';
}

# =============================================================================
# APPROACH 5: Alpine/postmarketOS style — busybox-only, ultra-minimal
# =============================================================================
#
# postmarketOS builds their initramfs with mkinitfs, which assembles:
#   - busybox (static, ~1.3 MB)
#   - A tiny init shell script
#   - Their pmos-initramfs hooks (device detection, unlocker, etc.)
#
# Alpine's mkinitfs uses: busybox, kmod, blkid, e2fsck — all statically linked
# or against musl.
#
# Key insight from postmarketOS: their init script is ~300 lines of shell
# that does everything initrd needs without ANY other package dependencies.
# The entire compressed initramfs is typically 3-8 MB.
#
# To replicate this in Nix:

{ pkgsCrossMusl }:
let
  pkgs = pkgsCrossMusl;

  # musl toolchain: static busybox, the ONLY binary needed
  staticBusybox = pkgs.busybox.override {
    enableStatic = true;
    # Optionally strip applets you don't need to shrink further:
    # extraConfig = ''
    #   CONFIG_FEATURE_WTMP n
    #   CONFIG_FEATURE_UTMP n
    # '';
  };

  # The init script — inspired by postmarketOS/Alpine
  pmosStyleInit = pkgs.writeScript "init-pmos" ''
    #!/bin/busybox sh
    # Ultra-minimal init — only busybox needed

    /bin/busybox --install -s /bin

    mount -t proc     proc     /proc
    mount -t sysfs    sysfs    /sys
    mount -t devtmpfs devtmpfs /dev
    mount -t tmpfs    tmpfs    /tmp
    mkdir -p /dev/pts
    mount -t devpts   devpts   /dev/pts

    echo /bin/mdev > /proc/sys/kernel/hotplug
    mdev -s

    hostname ipad-nixos

    # USB gadget via configfs
    mount -t configfs configfs /sys/kernel/config 2>/dev/null || true
    if [ -d /sys/kernel/config/usb_gadget ]; then
      mkdir -p /sys/kernel/config/usb_gadget/g0/functions/ecm.usb0
      mkdir -p /sys/kernel/config/usb_gadget/g0/configs/c.1
      echo c2:00:f0:01:00:01 > /sys/kernel/config/usb_gadget/g0/functions/ecm.usb0/host_addr
      echo c2:00:f0:01:00:02 > /sys/kernel/config/usb_gadget/g0/functions/ecm.usb0/dev_addr
      ln -sf /sys/kernel/config/usb_gadget/g0/functions/ecm.usb0 \
             /sys/kernel/config/usb_gadget/g0/configs/c.1/
      ls /sys/class/udc | head -1 | xargs -I{} sh -c \
        'echo {} > /sys/kernel/config/usb_gadget/g0/UDC'
    fi

    ip link set usb0 up    2>/dev/null || true
    ip addr add 192.168.7.2/24 dev usb0  2>/dev/null || true
    ip link set lo up      2>/dev/null || true

    exec sh
  '';

  # Pack everything manually — no makeInitrd overhead
  # Result: ~3-6 MB compressed (busybox ~1.3 MB, zstd -10 ~60% reduction)
in
pkgs.stdenvNoCC.mkDerivation {
  name = "ipad-initramfs-pmos";

  nativeBuildInputs = with pkgs.buildPackages; [ cpio zstd findutils ];

  buildCommand = ''
    mkdir -p root/{bin,sbin,dev,proc,sys,tmp,run,etc,var/empty,root}
    mkdir -p root/sys/kernel/config
    mkdir -p root/usr/{bin,sbin}
    chmod 700 root/root

    cp ${staticBusybox}/bin/busybox root/bin/busybox
    chmod +x root/bin/busybox

    cp ${pmosStyleInit} root/init
    chmod +x root/init

    # Minimal /etc
    printf 'root:x:0:0:root:/root:/bin/sh\n' > root/etc/passwd
    printf 'root:x:0:\n'                      > root/etc/group

    mkdir -p $out
    (cd root
      find . -print0 | sort -z \
      | cpio --quiet -o -H newc -R +0:+0 --reproducible --null \
      | zstd -10 > $out/initrd.zst)
    ln -s initrd.zst $out/initrd
  '';
}
