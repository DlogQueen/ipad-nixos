# iPad Air 2 (A8X) initramfs — minimal RAM-only root filesystem
#
# Build:
#   nix build .#initramfs
#
# Output:  result/initrd     (symlink → result/initrd.zst)
#          result/initrd.zst (the compressed cpio archive)
#
# This is called from flake.nix as:
#   pkgsCrossMusl.callPackage ./nixos/initramfs.nix {}
#
# Cross-compilation: x86_64-linux → aarch64-unknown-linux-musl
# Boot model: checkm8 → pongoOS → kernel → this initramfs as PID 1
# No internal NAND is ever mounted.  The entire system lives in RAM.
#
# Size estimate (busybox static + dropbear musl + kmod musl):
#   cpio uncompressed: ~35-55 MB  (Nix closure dominates; store paths are large)
#   zstd -10 output:  ~10-18 MB  (well within the 200 MB target)
#   RAM overhead:      ~60-80 MB  (kernel decompresses into RAM at boot)

{ lib
, makeInitrdNG     # pkgs.makeInitrdNG — the Rust-based cpio builder
, busybox          # will be overridden to static below
, dropbear
, kmod
, writeScript
}:

let
  # ---- static busybox -------------------------------------------------------
  # With pkgsCrossMusl (aarch64-unknown-linux-musl), busybox compiles against
  # musl libc.  Setting enableStatic = true adds -static to the link flags,
  # producing a single ~1.3 MB binary with no runtime .so dependencies.
  #
  # This is the only binary in the initramfs that must be static:
  # it is /init's interpreter (via the #!/bin/ash shebang) and must work
  # before any dynamic linker is configured.
  staticBusybox = busybox.override { enableStatic = true; };

  # ---- /init (PID 1) --------------------------------------------------------
  # The Linux kernel executes /init after unpacking the cpio archive.
  # This script must:
  #   1. Never exit (exit → kernel panic: "No working init found")
  #   2. Mount /proc, /sys, /dev before doing anything else
  #   3. Be executable (the cpio builder handles this via writeScript)
  #
  # The shebang resolves via the /bin symlink we add to contents below.
  initScript = writeScript "ipad-nixos-init" ''
    #!/bin/ash
    # PID 1 — this process must not exit.

    export PATH=/usr/local/bin:/bin:/sbin:/usr/bin:/usr/sbin

    # ---- pseudo-filesystems ------------------------------------------------
    mount -t proc     proc     /proc
    mount -t sysfs    sysfs    /sys
    # devtmpfs is preferred (kernel auto-populates /dev); fall back to plain tmpfs
    mount -t devtmpfs devtmpfs /dev 2>/dev/null || \
      mount -t tmpfs devtmpfs /dev
    mount -t tmpfs tmpfs /tmp
    mount -t tmpfs tmpfs /run

    mkdir -p /dev/pts /dev/shm
    mount -t devpts devpts /dev/pts

    # ---- mdev ---------------------------------------------------------------
    # BusyBox mdev: scan /sys and create missing /dev nodes, then listen for
    # uevents via the kernel hotplug mechanism.
    echo /bin/mdev > /proc/sys/kernel/hotplug
    mdev -s

    # Reduce kernel message noise on the console after initial boot
    echo 3 > /proc/sys/kernel/printk 2>/dev/null || true

    # ---- hostname -----------------------------------------------------------
    hostname ipad-nixos

    # ---- USB gadget Ethernet ------------------------------------------------
    #
    # Hardware path: A8X → Synopsys DWC2 OTG at 0x10200000 → USB Type-A port
    # Kernel config: USB_GADGET=y  USB_CONFIGFS=y  USB_CONFIGFS_ECM=y
    #                USB_ETH=m     USB_ETH_RNDIS=y  USB_DWC2=y
    #
    # The gadget presents as ECM (Ethernet Control Model) to the host ThinkPad.
    # Once the host side has 192.168.7.1 configured (see docs/plans/phase1),
    # SSH will work from the ThinkPad to the iPad at 192.168.7.2.
    setup_usb_gadget() {
      # Mount configfs (needed for USB gadget ConfigFS API)
      mount -t configfs configfs /sys/kernel/config 2>/dev/null || true

      if [ -d /sys/kernel/config/usb_gadget ]; then
        G=/sys/kernel/config/usb_gadget/ipad-nixos

        mkdir -p "$G"
        printf '0x1d6b' > "$G/idVendor"    # Linux Foundation
        printf '0x0104' > "$G/idProduct"   # Multifunction Composite Gadget
        printf '0x0100' > "$G/bcdDevice"
        printf '0x0200' > "$G/bcdUSB"

        mkdir -p "$G/strings/0x409"
        printf 'ipad-nixos-000001' > "$G/strings/0x409/serialnumber"
        printf 'iPad (NixOS)'      > "$G/strings/0x409/manufacturer"
        printf 'iPad NixOS Gadget' > "$G/strings/0x409/product"

        # ECM function
        # Stable host_addr so the ThinkPad always sees the same MAC (usb0 won't
        # renumber to usb1 after a reconnect).
        mkdir -p "$G/functions/ecm.usb0"
        printf 'c2:00:f0:01:00:01' > "$G/functions/ecm.usb0/host_addr"
        printf 'c2:00:f0:01:00:02' > "$G/functions/ecm.usb0/dev_addr"

        mkdir -p "$G/configs/c.1/strings/0x409"
        printf 'ECM'  > "$G/configs/c.1/strings/0x409/configuration"
        printf '250'  > "$G/configs/c.1/MaxPower"

        ln -sf "$G/functions/ecm.usb0" "$G/configs/c.1/" 2>/dev/null || true

        # Bind to the DWC2 UDC.  On A8X the UDC shows up as something like
        # "10200000.usb" in /sys/class/udc/.
        UDC="$(ls /sys/class/udc 2>/dev/null | head -1)"
        if [ -n "$UDC" ]; then
          printf '%s' "$UDC" > "$G/UDC"
          echo "[usb] ECM gadget bound to: $UDC"
        else
          echo "[usb] No UDC found in /sys/class/udc"
          echo "[usb] Check: dmesg | grep dwc2"
        fi

      else
        # Fallback: load g_ether as a standalone module (USB_ETH=m required)
        if modprobe g_ether \
             host_addr=c2:00:f0:01:00:01 \
             dev_addr=c2:00:f0:01:00:02 2>/dev/null; then
          echo "[usb] Loaded g_ether module (fallback path)"
        else
          echo "[usb] ERROR: configfs not available and g_ether modprobe failed"
          echo "[usb] Kernel may need USB_CONFIGFS=y or USB_ETH=y (not m)"
        fi
      fi
    }

    setup_usb_gadget

    # ---- bring up usb0 ------------------------------------------------------
    # Poll for up to 5 seconds; the gadget needs a moment after binding to UDC.
    i=0
    while [ $i -lt 10 ]; do
      ip link show usb0 >/dev/null 2>&1 && break
      sleep 0.5
      i=$((i+1))
    done

    if ip link show usb0 >/dev/null 2>&1; then
      ip link set usb0 up
      ip addr add 192.168.7.2/24 dev usb0
      echo "[net] usb0: 192.168.7.2/24 (host should be 192.168.7.1)"
    else
      echo "[net] usb0 did not appear — USB gadget may not have bound"
    fi

    # loopback
    ip link set lo up 2>/dev/null || true
    ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true

    # ---- /etc minimal setup -------------------------------------------------
    mkdir -p /etc /var/log /var/run /var/empty /root/.ssh
    chmod 700 /root

    # Minimal passwd/group — required by dropbear session handling
    # and by getpwuid() calls in any libc-linked binary.
    cat > /etc/passwd << 'PASSWD'
root:x:0:0:root:/root:/bin/ash
nobody:x:65534:65534:Nobody:/var/empty:/bin/false
PASSWD

    cat > /etc/group << 'GROUP'
root:x:0:root
nobody:x:65534:nobody
GROUP

    cat > /etc/nsswitch.conf << 'NSS'
passwd:   files
group:    files
shadow:   files
hosts:    files dns
NSS

    cat > /etc/resolv.conf << 'RESOLV'
nameserver 192.168.7.1
RESOLV

    # ---- dropbear SSH host keys (generated at boot) -------------------------
    # Keys are regenerated each boot because the filesystem is not persistent.
    # For stable host key fingerprints, bake pre-generated keys into the initrd
    # by adding them to the `contents` list below.
    mkdir -p /etc/dropbear
    dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key \
      2>/var/log/dropbear-keygen.log
    dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key \
      2>>/var/log/dropbear-keygen.log

    echo "[ssh] Host key fingerprint:"
    dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null \
      | grep Fingerprint || true

    # ---- authorized_keys -----------------------------------------------------
    # The initrd has no authorized_keys baked in.  Add yours here or copy it
    # over the USB connection before SSHing.
    #
    # To bake a key in, add to `contents` in this file:
    #   { source = ./authorized_keys; target = "/root/.ssh/authorized_keys"; }
    # Then rebuild: nix build .#initramfs

    # ---- dropbear SSH daemon ------------------------------------------------
    # -s   disable password auth (key-only); protects against brute force
    # -g   permit root login
    # -E   log to stderr
    # -p   port
    # Backgrounded with &; PID 1 (this script) continues.
    dropbear -s -g -E -p 22 \
      -r /etc/dropbear/dropbear_ed25519_host_key \
      2>/var/log/dropbear.log &

    DROPBEAR_PID=$!
    # Brief pause to let dropbear start up
    sleep 1
    if kill -0 "$DROPBEAR_PID" 2>/dev/null; then
      echo "[ssh] dropbear running on :22 (key auth only)"
      echo "[ssh] Add public key to /root/.ssh/authorized_keys"
      echo "[ssh] Connect: ssh root@192.168.7.2"
    else
      echo "[ssh] dropbear failed — see /var/log/dropbear.log"
    fi

    # ---- getty on framebuffer (/dev/tty1) -----------------------------------
    # The simple-framebuffer DRM driver will initialise the display using the
    # framebuffer pongoOS set up (2224×1668 on iPad Air 2 Retina panel).
    # getty on tty1 gives an interactive console on the iPad screen itself.
    setsid getty -L tty1 0 vt100 &

    # ---- banner -------------------------------------------------------------
    echo ""
    echo "========================================="
    echo " iPad NixOS — $(uname -r)"
    echo " Console: $(tty)"
    echo "========================================="
    echo " SSH: ssh root@192.168.7.2"
    echo "      (add authorized_keys first)"
    echo " Logs: /var/log/dropbear.log"
    echo "========================================="
    echo ""

    # ---- serial console shell (PID 1 main loop) -----------------------------
    # The serial UART on A8X appears as the Samsung UART (SERIAL_SAMSUNG).
    # pongoOS routes console output there; the kernel inherits it.
    # Exec into ash so this PID-1 process becomes the interactive shell.
    # The kernel will panic if this process exits.
    exec /bin/ash
  '';

  # ---- pre-baked host keys (optional) ---------------------------------------
  # Generate these once and check them in so the host key fingerprint is
  # stable across reboots.  Regenerate with:
  #   dropbearkey -t ed25519 -f dropbear_ed25519_host_key
  #   chmod 600 dropbear_ed25519_host_key
  # Then add to contents:
  #   { source = ./secrets/dropbear_ed25519_host_key;
  #     target = "/etc/dropbear/dropbear_ed25519_host_key"; }
  # DO NOT check private key files into git; use git-crypt or sops-nix.

in
# =============================================================================
# makeInitrdNG — the actual build target
# =============================================================================
#
# makeInitrdNG interface (from make-initrd-ng.nix):
#
#   contents : list of { source = <storePath>; target = "/abs/path"; }
#
#   For each entry:
#     - source must be a Nix store path (derivation output or file)
#     - target is the absolute path in the cpio root where it appears
#     - If source is a file: copied to target; ELF deps walked and included
#     - If source is a directory: recursively copied to target (symlinks followed
#       one level); ELF deps of all contained binaries walked and included
#     - The Nix store paths of all deps appear in the cpio at their canonical
#       /nix/store/<hash>-name/... paths so ELF interpreters resolve
#
#   compressor: name from initrd-compressor-meta.nix, or a function
#     pkgs: "${pkgs.tool}/bin/tool"
#   compressorArgs: null (use defaults) or list of strings
#
#   prepend: list of uncompressed cpio archives to concatenate before the
#     main archive (useful for CPU microcode blobs — not needed for ARM)
#
#   makeUInitrd: wrap in U-Boot uImage (false for direct kernel boot)
#
makeInitrdNG {
  compressor = "zstd";
  # zstd default is -10; override with:
  # compressorArgs = [ "-15" ];

  contents = [
    # ---- PID 1 --------------------------------------------------------------
    # The kernel searches: /init /sbin/init /etc/init /bin/init
    # We use /init (first in the search order).
    # makeInitrdNG copies this script and walks any ELF dependencies
    # (none here — it's a shell script; ash itself is in /bin below).
    {
      source = initScript;
      target = "/init";
    }

    # ---- BusyBox (static) ---------------------------------------------------
    # Single binary with all applets.  Static: no .so deps to worry about.
    # We copy the bin/ and sbin/ trees so applets are accessible as
    # /bin/ash, /bin/ip, /bin/mount, /sbin/mdev, /bin/getty, etc.
    #
    # makeInitrdNG behaviour with directories:
    #   - Copies the directory recursively to target
    #   - For each file inside, walks ELF NEEDED entries (busybox has none,
    #     it's static, but the tool still checks and finds nothing to add)
    #   - Symlinks inside the source dir are recreated in the cpio
    {
      source = "${staticBusybox}/bin";
      target = "/bin";
    }
    {
      source = "${staticBusybox}/sbin";
      target = "/sbin";
    }

    # ---- dropbear SSH -------------------------------------------------------
    # dropbear is dynamically linked against musl (from pkgsCrossMusl).
    # makeInitrdNG's Rust tool reads the ELF NEEDED entries and copies all
    # shared library deps into the cpio at their /nix/store/... paths.
    #
    # These go in /usr/local/bin to avoid collision with BusyBox's /bin
    # (which is a read-only symlink to the BusyBox store path).
    {
      source = "${dropbear}/bin/dropbear";
      target = "/usr/local/bin/dropbear";
    }
    {
      source = "${dropbear}/bin/dropbearkey";
      target = "/usr/local/bin/dropbearkey";
    }
    {
      source = "${dropbear}/bin/dbclient";
      target = "/usr/local/bin/dbclient";
    }

    # ---- kmod ---------------------------------------------------------------
    # modprobe is needed for g_ether, brcmfmac, btbcm, etc.
    # Also in /usr/local/bin to avoid /bin collision.
    {
      source = "${kmod}/bin/kmod";
      target = "/usr/local/bin/kmod";
    }
    {
      source = "${kmod}/bin/modprobe";
      target = "/usr/local/bin/modprobe";
    }
    {
      source = "${kmod}/bin/lsmod";
      target = "/usr/local/bin/lsmod";
    }
    {
      source = "${kmod}/bin/insmod";
      target = "/usr/local/bin/insmod";
    }
    {
      source = "${kmod}/bin/rmmod";
      target = "/usr/local/bin/rmmod";
    }
  ];
  # makeInitrdNG pre-creates: /run, /tmp, /var/empty, /var/run → ../run
  # We create /proc /sys /dev /etc /root in the init script via mkdir.
}
