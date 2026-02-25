# Custom Linux kernel for iPad Air 2 (A8X / T7001)
#
# Key differences from standard aarch64 kernel:
# - 16KB pages (Apple SoCs use 16KB, not 4KB)
# - Apple platform drivers (AIC, SPI, watchdog, GPIO)
# - Z2 touch protocol driver (for BCM5976 touch controller)
# - USB gadget networking (primary network interface during bring-up)
# - Simple framebuffer (display initialized by iBoot/pongoOS)

{ lib
, buildLinux
, fetchurl
, ...
} @ args:

buildLinux (args // {
  version = "6.19.3";
  modDirVersion = "6.19.3";

  src = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.19.3.tar.xz";
    hash = "sha256-DkdJaK38vuMpFv0BqJ2Mz9EWjY0yVp52pcZkx5MZjr4=";
  };

  # Disable strict config checking — we enable COMPILE_TEST which pulls in
  # many optional configs that may conflict with cross-compilation
  ignoreConfigErrors = true;

  structuredExtraConfig = with lib.kernel; {
    # --- Page size (Apple SoCs require 16KB) ---
    ARM64_16K_PAGES = yes;

    # --- Apple platform support ---
    # ARCH_APPLE is for M-series Macs; A-series iPads use generic ARM64
    # COMPILE_TEST unlocks drivers gated on ARCH_APPLE
    COMPILE_TEST = yes;

    # Apple Interrupt Controller (same IP block A7 through M4)
    APPLE_AIC = yes;

    # Apple watchdog timer
    APPLE_WATCHDOG = yes;

    # Apple GPIO / pin controller
    PINCTRL_APPLE_GPIO = yes;

    # --- SPI bus (required for touch controller) ---
    SPI = yes;
    SPI_MASTER = yes;
    SPI_APPLE = yes;

    # --- Touch (BCM5976 via Z2 protocol) ---
    INPUT_TOUCHSCREEN = yes;
    TOUCHSCREEN_APPLE_Z2 = yes;

    # --- Display (framebuffer initialized by pongoOS) ---
    DRM = yes;
    DRM_SIMPLEDRM = yes;
    FB = yes;
    FB_SIMPLE = yes;
    FRAMEBUFFER_CONSOLE = yes;
    BACKLIGHT_CLASS_DEVICE = yes;

    # --- Serial console (Apple UART is Samsung S3C compatible) ---
    SERIAL_SAMSUNG = yes;
    SERIAL_SAMSUNG_CONSOLE = yes;

    # --- USB (Synopsys DWC2 OTG) ---
    USB = yes;
    USB_DWC2 = yes;
    USB_DWC2_DUAL_ROLE = yes;

    # --- USB gadget (for USB Ethernet to host machine) ---
    USB_GADGET = yes;
    USB_CONFIGFS = yes;
    USB_CONFIGFS_ECM = yes;
    USB_CONFIGFS_RNDIS = yes;
    USB_ETH = module;
    USB_ETH_RNDIS = yes;

    # --- Networking ---
    NET = yes;
    INET = yes;
    IPV6 = yes;
    NETDEVICES = yes;

    # --- WiFi (Broadcom BCM4354 via brcmfmac) ---
    WLAN = yes;
    CFG80211 = module;
    BRCMFMAC = module;

    # --- Bluetooth (BCM4354 via btbcm) ---
    BT = module;
    BT_HCIUART = module;
    BT_BCM = module;

    # --- initramfs (entire rootfs runs from RAM) ---
    BLK_DEV_INITRD = yes;
    RD_LZMA = yes;
    RD_GZIP = yes;
    RD_ZSTD = yes;

    # --- Sensors (Bosch accelerometer/barometer have mainline drivers) ---
    IIO = module;
    BMA180 = module;
    BMP280 = module;

    # --- Battery fuel gauge (TI BQ27546) ---
    BATTERY_BQ27XXX = module;
    BATTERY_BQ27XXX_I2C = module;

    # --- Misc required infrastructure ---
    DEVTMPFS = yes;
    DEVTMPFS_MOUNT = yes;
    TMPFS = yes;
    PROC_FS = yes;
    SYSFS = yes;

    # --- TTY / console ---
    VT = yes;
    VT_CONSOLE = yes;
    UNIX98_PTYS = yes;
  };

  extraMeta = {
    branch = "6.19";
    description = "Linux kernel for iPad Air 2 (A8X) with 16KB pages and Apple drivers";
    platforms = [ "aarch64-linux" ];
  };
} // (args.argsOverride or {}))
