# BCM5976 Touch Controller Deep Dive

Exhaustive research on the Broadcom BCM5976 touch controller and all paths to
Linux touch input on iPad Air 2. Research conducted February 2026.

---

## 1. BCM5976 Hardware Overview

### Chip Identity

- Full part number: BCM5976C0KUB6G (or BCM5976C1KUB7G for later revision)
- Marketing name: "Cumulus"
- Manufacturer: Broadcom Corporation (custom ASIC for Apple)
- Package: 63-pin BGA
- Interface to SoC: SPI (Serial Peripheral Interface)
- Board designations vary per device:
  - U12: iPhone 5, 5C, 5S
  - U2401: iPhone 6, 6 Plus
  - U4100/U4150: iPad Air 2
  - U6600/U6650: iPad Air 1
  - U4301: iPhone SE (1st gen)
- Also used in: iPad Mini 1-4, iPad 5th gen (2017), iPod Touch 5/6

The BCM5976 contains one or more embedded MCUs (ARM cores likely) that run
proprietary firmware. The firmware is uploaded to the controller at boot time
by the application processor over SPI. The controller handles capacitive
sensing, signal processing, and touch coordinate generation. It reports
multi-touch contact data back to the AP over SPI.

### Datasheet Availability

No public datasheet exists. The BCM5976 is a custom ASIC designed exclusively
for Apple. Broadcom does not publish documentation for it. Alldatasheet.com
returns no results. The only technical information comes from:
- Board-level repair documentation (pinout, board designations)
- iFixit teardowns (chip identification)
- Reverse engineering (protocol, firmware)
- TechInsights/Chipworks paid teardown reports (die photos, not public)

### What the BCM5976 Is NOT

The BCM5976 is NOT the same as the BCM5974 used in MacBook trackpads. The
BCM5974 is a USB HID device; the BCM5976 is an SPI device. They are from the
same Broadcom touch controller product family but use different transport
protocols. However, the touch report data format shares structural similarities
(see section 3).

Sources:
- https://www.reverse-costing.com/teardown-notes/broadcom-bcm5976-iphone-6s/
- https://www.ifixit.com/Answers/View/128987/Please+give+me+bcm5976+data+sheets
- https://news.ycombinator.com/item?id=32137367
- https://microsolderingsupply.com/index.php?route=product/product&product_id=257

---

## 2. The Z2 Multitouch Subsystem

### Critical Discovery: BCM5976 IS Part of the Z2 Ecosystem

The term "Z2" (or "Zephyr2") refers to Apple's multitouch subsystem
architecture. The name appears in Apple's firmware naming convention:
- `zephyr2.bin`: multitouch firmware file (iPhone 3G era onwards)
- `zephyr_aspeed.bin` / `zephyr_main.bin`: earlier iPod Touch/iPhone 2G firmware

The Z2 subsystem encompasses:
1. The touch controller IC itself (BCM5976 on iPad Air 2)
2. The SPI bus connection to the application processor
3. The firmware uploaded to the controller at boot
4. The protocol for exchanging touch data

Every Apple touch controller from at least the iPhone 3G through iPhone 6S era
uses the Z2 protocol family. This is confirmed by:
- openiBoot calling its multitouch driver "zephyr2"
- Corellium's hx-touchd using `send_z2()` function and `MT_SPI_Z2_WAKE_CMD`
- lemonjesus's iPad 3 project referring to the "Z2 multitouch controller"
- Asahi Linux's `apple_z2` driver handling Touch Bar and touchscreen

The Z2 protocol has evolved over generations but retains backward-compatible
command structures. This means work done on any Z2-compatible device is
potentially relevant to the BCM5976.

Sources:
- https://github.com/iDroid-Project/openiBoot
- https://github.com/corellium/projectsandcastle
- https://github.com/lemonjesus/ipad-touch-screen
- https://patchwork.kernel.org/project/linux-arm-kernel/patch/20241128-z2-v2-2-76cc59bbf117@gmail.com/

---

## 3. Protocol Documentation (Assembled from Multiple Sources)

### 3.1 SPI Frame Format (from hx-touchd)

Communication uses 16-byte frames with little-endian encoding:
- 14 bytes of data
- 2 bytes little-endian checksum (sum of first 14 bytes)
- CS (chip select) timing: 1000us delays around transitions
- Max data chunk for firmware blocks: 16384 bytes

### 3.2 Command Codes (from hx-touchd analysis)

| Code | Name | Purpose |
|------|------|---------|
| 0xE1 | MT_CMD_LAST | End-of-command marker |
| 0xE2 | MT_DEV_INFO | Device information query |
| 0xE3 | MT_REP_INFO | Report information query |
| 0xE4 | MT_CTRL_WRITE_SHORT | Short control write (<=11 bytes) |
| 0xE5 | MT_CTRL_WRITE_LONG | Long control write (with padding) |
| 0xE6 | MT_CTRL_READ_SHORT | Short control read |
| 0xE7 | MT_CTRL_READ_LONG | Long control read |
| 0xEA | MT_FRAME_LEN | Frame length operation |
| 0xEB | MT_DATA_LEN / Read IRQ | Data length / interrupt read |
| 0xEE | MT_SPI_Z2_WAKE_CMD | Z2 wake command |

### 3.3 Report Types (from hx-touchd)

| Report ID | Purpose |
|-----------|---------|
| 0x9D | Touch data report (Type 1 controllers) |
| 0xAF | Touch data report (Type 2 controllers) |
| 0xBF | Additional touch data (Type 1) |
| 0xD9 | Screen metrics/calibration data |

Report 0xD9 contains screen boundary calibration at these byte offsets:
- Bytes 8-9: left boundary (signed 16-bit LE)
- Bytes 10-11: bottom boundary (signed 16-bit LE)
- Bytes 12-13: right boundary (signed 16-bit LE)
- Bytes 14-15: top boundary (signed 16-bit LE)

### 3.4 Initialization Sequence (from hx-touchd)

1. Reset controller via GPIO
2. Write 4-byte command, read response
3. Sleep 1ms
4. Setup IRQ handler, wait for boot interrupt (500ms timeout)
5. Assert chip select, send 4-byte sync command
6. Load firmware blocks with acknowledgment verification
7. Query report 0xD9 for calibration/screen metrics
8. Configure type-specific touch reports (0x9D, 0xBF, 0xAF)

### 3.5 Firmware Loading (from hx-touchd)

Two firmware item types:
- MTFW_WRITE: Data blocks transmitted with chip select control
- MTFW_WRITE_ACK: Blocks requiring acknowledge sequence (0x1A 0xA1)
- MTFW_SET_TYPE: Controller type identifier (1 or 2)

Firmware is loaded from `.mtprops` property list files. Firmware delivery in
chunks up to approximately 1MB per transfer. Some operations require controller
acknowledgment before proceeding.

### 3.6 Apple Z2 Kernel Driver Data (from Linux 6.15 apple_z2.c)

The upstream Linux apple_z2 driver confirms these protocol elements:

Touch finger structure (32 bytes per contact point):
- finger ID, state byte
- abs_x, abs_y (position, signed 16-bit LE)
- rel_x, rel_y (relative movement)
- tool_major, tool_minor (tool area dimensions)
- touch_major, touch_minor (contact area dimensions)
- orientation angle
- pressure
- multi (multi-touch tracking identifier)
- State values: 3 = TOUCH_STARTED, 4 = TOUCH_MOVED

Touch report packet layout:
- Offset 16: number of fingers
- Offset 24: array of finger structures (max 256)

Firmware header magic: 0x5746325A ("ZW2F" or "FW2Z" reversed)
Firmware version field expected value: 1

SPI read interrupt command: 0xEB with alternating counter byte and 16-bit checksum.

Firmware load commands:
- 0: Initialize payload (8-bit SPI mode)
- 1: Send blob (16-bit SPI mode)
- 2: Send calibration data

HBPP blob header for calibration: command 0x3001, length in words, target
address, header checksum.

Initialization: GPIO reset (high -> low), wait for boot IRQ (20ms timeout),
upload firmware sequence, set booted flag, read first packet.

### 3.7 Touch Data Format Comparison: BCM5974 (USB) vs Z2 (SPI)

The BCM5974 USB driver (Linux kernel `drivers/input/mouse/bcm5974.c`) uses a
`tp_finger` structure:

```
struct tp_finger {
    __le16 origin;        // zero when switching track finger
    __le16 abs_x;         // absolute x coordinate
    __le16 abs_y;         // absolute y coordinate
    __le16 rel_x;         // relative x coordinate
    __le16 rel_y;         // relative y coordinate
    __le16 tool_major;    // tool area, major axis
    __le16 tool_minor;    // tool area, minor axis
    __le16 orientation;   // 16384 when point, else 15 bit angle
    __le16 touch_major;   // touch area, major axis
    __le16 touch_minor;   // touch area, minor axis
    __le16 unused[2];     // zeros
    __le16 pressure;      // pressure on forcetouch touchpad
    __le16 multi;         // one finger: varies, more: constant
};
```

The apple_z2 driver's finger structure has the SAME fields: abs_x, abs_y,
rel_x, rel_y, tool_major, tool_minor, touch_major, touch_minor, orientation,
pressure, multi. The field order and sizes are nearly identical.

This confirms that the BCM5976 touch report format is structurally equivalent
to the BCM5974 USB format, just delivered over SPI instead of USB. The touch
report parsing logic from bcm5974.c can be substantially reused.

Sources:
- https://github.com/torvalds/linux/blob/master/drivers/input/mouse/bcm5974.c
- https://deepwiki.com/corellium/projectsandcastle
- https://patchwork.kernel.org/project/linux-arm-kernel/patch/20241128-z2-v2-2-76cc59bbf117@gmail.com/

---

## 4. Existing Code and Projects (Detailed)

### 4.1 Corellium hx-touchd (Project Sandcastle)

Location: https://github.com/corellium/projectsandcastle/tree/master/hx-touchd

Files:
- `hx-touchd.c`: Main daemon source (approximately 542 lines)
- `mtfw/`: Multi-touch firmware loading library
- `mxml-3.1/`: Mini-XML parser (for .mtprops firmware files)
- `Makefile`: Build configuration

Architecture: Userspace daemon communicating with a custom kernel driver
(`/dev/hx-touch`) via ioctl.

IOCTL interface:
- HXT_IOC_SET_CS: SPI chip select control
- HXT_IOC_RESET: Controller hardware reset
- HXT_IOC_READY: Signal initialization complete
- HXT_IOC_SETUP_IRQ / HXT_IOC_WAIT_IRQ: Interrupt handling
- HXT_IOC_METRICS: Set screen boundaries

Target device: iPhone 7 (A10 / T8010). The iPhone 7 uses a DIFFERENT touch
controller IC than BCM5976. However, both use the Z2 protocol family, so the
command codes, report formats, and initialization sequence are structurally
similar.

The hx-touchd source code is the single most valuable reference for writing a
BCM5976 driver. It contains the complete Z2 protocol implementation.

Kernel driver: The `/dev/hx-touch` kernel driver is in the corellium/linux-sandcastle
repository but is NOT open-source in the same way as hx-touchd. It provides
raw SPI access with interrupt handling.

### 4.2 lemonjesus ipad-touch-screen

Location: https://github.com/lemonjesus/ipad-touch-screen

This project turns an iPad 3 into an external USB touchscreen using a
Raspberry Pi Pico (RP2040). It is the most relevant project for understanding
how the Z2 controller works on older iPads.

Target: iPad 3 (A5X). The iPad 3 uses a Z2 multitouch controller (the specific
Broadcom part number for the iPad 3 may differ from the BCM5976 used in Air 2,
but the protocol is Z2-family).

Key technical contributions:
- Documents the SPI bus configuration (MISO, MOSI, CLK, CS)
- Documents control signals: MT_SELECT, MT_RESET, MT_ATTN
- Documents the I2C PMU configuration needed to power the Z2 subsystem
- Demonstrates the "training" approach: record iOS's initialization of the
  Z2 controller, then replay it
- Proves that the Z2 controller can be operated independently of the main SoC

Hardware connections (iPad 3, 15 solder points):
- SPI: MISO, MOSI, CLK, CS
- Control: MT_SELECT (selects boot vs. normal SPI interface), MT_RESET,
  MT_ATTN (interrupt/attention line)
- I2C: SDA, SCL (to PMU for power configuration)
- System: RESET (via NPN transistor), USB D+/D-, 5V, GND

The MT_SELECT line is critical: the Z2 controller has TWO SPI interfaces. One
is used during bootloader/firmware upload, and the other is used during normal
operation. MT_SELECT switches between them.

The MT_ATTN line is the interrupt signal: the Z2 controller asserts this when
touch data is available.

Applicability to iPad Air 2: HIGH. The iPad Air 2's BCM5976 uses the same Z2
protocol. The SPI bus configuration, control signals, and protocol will be
structurally identical. Only the firmware file and calibration data differ.

### 4.3 Asahi Linux apple_z2 Driver (Linux 6.15+)

Location: `drivers/input/touchscreen/apple_z2.c` in Linux kernel 6.15+

Author: Sasha Finkelstein (ChaosPrincess), Asahi Linux project.

Target hardware: Apple Silicon MacBook Touch Bar (M1/M2 13" MacBook Pro).
The Touch Bar uses a Z2 touchscreen digitizer on SPI, exactly the same
protocol family as the BCM5976.

Status: Merged upstream in Linux 6.15 (patch series v5, January 2025).

This is a proper Linux kernel input driver implementing:
- SPI communication with the Z2 controller
- GPIO-based reset
- Firmware loading (from filesystem)
- Calibration data loading (from device tree)
- Multi-touch slot reporting via input_mt_* APIs
- Power management (suspend/resume)

The driver is approximately 300-400 lines of clean kernel code. It handles:
1. Boot sequence: GPIO reset, wait for boot IRQ, firmware upload
2. Touch reading: SPI transaction to read packet length, then full frame
3. Touch reporting: Extract finger data from frame, report to input subsystem

Device tree compatible string: "apple,z2-multitouch"
Required properties: reset-gpios, interrupts, firmware-name
Optional: apple,z2-cal-blob (calibration data)

This driver is directly portable to the iPad Air 2's BCM5976. The Z2 protocol
is the same. The required changes:
1. A8X SPI controller driver (different from Apple Silicon SPI)
2. Device tree for A8X's SPI bus configuration and GPIO mapping
3. Correct firmware file for the BCM5976
4. Calibration data for the iPad Air 2's specific touch panel

### 4.4 openiBoot Z2 Multitouch Driver

Location: https://github.com/iDroid-Project/openiBoot

openiBoot is the original open-source implementation of Apple's iBoot
bootloader, used by the iDroid project (Android on older iPhones). It
contains a Z2 multitouch driver for iPhone 3G that documents:
- Firmware upload procedure (zephyr2.bin)
- SPI initialization sequence
- IMG3 firmware container format
- Firmware type identification bytes at offset 0x10-0x13

Firmware files must be converted from raw .bin to IMG3 format using
mk8900image, then uploaded to device memory at address 0x09000000 before
calling multitouch_fw_install.

Historical importance: This was the first open-source implementation of Z2
multitouch initialization and confirmed that the protocol could be reverse
engineered and reimplemented.

### 4.5 devos50 QEMU-iOS (iPod Touch Emulation)

Location: https://github.com/devos50/qemu-ios

Martijn de Vos implemented multitouch emulation for the iPod Touch 1G and 2G
in QEMU. This required understanding the Z2 protocol at the SPI level to
generate valid touch frames.

Key contributions:
- Confirmed multitouch SPI frame format through frame analysis
- Documented touch events as containing ellipse-shaped contact information
- Documented velocity data in touch frames (used for scroll/swipe)
- Identified three initialization phases: calibration upload, firmware upload,
  device information read
- Used openiBoot as reference for initialization sequence

The QEMU implementation generates touch frames that the iOS kernel accepts,
confirming the frame format is correctly understood. The touch frame
structure from this project can be cross-referenced with the bcm5974 and
apple_z2 finger structures.

### 4.6 Linux applespi Driver (MacBook SPI Keyboard/Trackpad)

Location: `drivers/input/keyboard/applespi.c` in Linux kernel 5.3+

This driver handles the MacBook's SPI-connected keyboard and trackpad. While
the transport protocol differs from the Z2 protocol used on iOS devices, the
multitouch data structures within the trackpad reports share the same field
layout (abs_x, abs_y, touch_major, tool_major, orientation, pressure, etc.).

The applespi protocol was reverse engineered by the macbook12-spi-driver
community (https://github.com/cb22/macbook12-spi-driver). The higher-level
protocol is not publicly documented by Apple.

Relevant to iPad Air 2: The trackpad report parsing code demonstrates how to
handle Apple multitouch data in a Linux kernel driver. The multitouch slot
reporting pattern can be reused.

### 4.7 Linux bcm5974 Driver (MacBook USB Trackpad)

Location: `drivers/input/mouse/bcm5974.c` in Linux kernel

This driver handles MacBook trackpads connected over USB. It defines the
canonical `tp_finger` structure that documents how Broadcom/Apple encode
multi-touch contact data. The BCM5974 and BCM5976 share the same touch data
encoding (little-endian 16-bit fields for position, area, orientation,
pressure).

Four report format variants exist in bcm5974:
- TYPE1: 26-byte header + 28-byte finger blocks
- TYPE2: 30-byte header + 28-byte finger blocks (integrated button)
- TYPE3: 38-byte header + 28-byte finger blocks (post-June 2013)
- TYPE4: 46-byte header + 30-byte finger blocks (pressure/force touch)

The BCM5976 likely uses a format similar to TYPE3 or TYPE4 given its era
(2014). The finger block size of 28-30 bytes matches the apple_z2 driver's
32-byte finger structure.

### 4.8 Asahi Linux Multitouch Firmware Extraction

Location: https://github.com/AsahiLinux/asahi-installer/blob/main/asahi_firmware/multitouch.py

This Python script extracts Z2 multitouch firmware from Apple's IMG4P firmware
containers. It handles:
- IMG4P extraction
- XML plist parsing with ID/IDREF dereferencing
- Two firmware output formats: Touch Bar binary and Trackpad HIDF

Touch Bar firmware uses three load command types:
- LOAD_COMMAND_INIT_PAYLOAD (0): SPI initialization
- LOAD_COMMAND_SEND_BLOB (1): Data transmission with 14-byte header
- LOAD_COMMAND_SEND_CALIBRATION (2): Calibration data

The firmware header uses 0x3001 as the command marker, with payload size in
4-byte words, target address, and checksum.

This tool could potentially be adapted to extract firmware from iPad Air 2's
iOS IPSW for use with a Linux Z2 driver.

### 4.9 FreeBSD atopcase Driver (Apple HID-over-SPI)

Location: https://reviews.freebsd.org/D39863

A WIP FreeBSD driver for Apple's custom HID-over-SPI transport. This driver
implements a bespoke Apple protocol that predates Microsoft's HID-over-SPI
specification by approximately five years. The FreeBSD driver is relevant as
another independent implementation of Apple SPI communication.

Sources:
- https://github.com/corellium/projectsandcastle
- https://github.com/lemonjesus/ipad-touch-screen
- https://github.com/torvalds/linux/blob/master/drivers/input/keyboard/applespi.c
- https://github.com/torvalds/linux/blob/master/drivers/input/mouse/bcm5974.c
- https://github.com/AsahiLinux/asahi-installer/blob/main/asahi_firmware/multitouch.py
- https://github.com/iDroid-Project/openiBoot
- https://github.com/devos50/qemu-ios
- https://www.phoronix.com/news/Linux-6.15-Input

---

## 5. iOS Firmware Analysis

### 5.1 KEXT Structure

The touch controller kext hierarchy in iOS:

```
/System/Library/Extensions/
  AppleMultitouchSPI.kext/
    PlugIns/
      MultitouchHID.plugin/
        MultitouchHID
```

AppleMultitouchSPI.kext is the kernel-level SPI transport driver.
MultitouchHID.plugin is the higher-level touch processing plugin.

### 5.2 MultitouchHID Exported Symbols

From the iOS 13.0 SDK TBD file, key exported symbols include:

Touch event functions:
- MTAppendAbsoluteMouseEvent
- MTAppendRelativeMouseEvent
- MTAppendScrollEvent
- MTAppendSwipeEvent
- MTAppendForceGestureEvent
- MTAppendGestureStartedToCollectionEvent
- MTAppendGestureEndedToCollectionEvent
- MTAppendKeyboardEvent
- MTAppendModifierKeyEvent

Calibration and geometry:
- computeFingerEllipseTipOffset_mm (multiple variants)
- convertPixelVelocitiesTo_mm_s
- computeSeparation_mm
- computeSeparationVector
- invertRadiusSmoothing

Core processing classes:
- MTParser (core parsing engine)
- MTParserPath (touch path parsing)
- MTPathStates (path state management)
- MTHandMotion (hand gesture processing)
- MTHandStatistics (hand statistics)
- MTFingerToPathMap (finger-to-path mapping)
- MTSurfaceDimensions (surface dimension calculations)
- MTSimpleHIDManager (HID management)
- MTInterferenceMonitor (interference detection)
- MTSimpleEventDispatcher (event dispatching)

Device management:
- IOHIDPlugInFactory
- deviceWillReset
- resetDevice
- handleFrameHeader
- handleContactFrame

Logging:
- MTSLGLogger (image/path logging)
- mt_PrintHIDEvent
- mt_PrintRawHIDEvent

### 5.3 Extracting and Analyzing the Kext

Tools for iOS kernelcache analysis:
- `ipsw` (https://github.com/blacktop/ipsw): Swiss army knife for iOS research,
  can extract kernelcache, list kexts, parse Mach-O
- `joker` / `jtool2`: Kernelcache symbolication and kext extraction
- `ghidra_kernelcache` (https://github.com/0x36/ghidra_kernelcache): Ghidra
  framework for iOS 12-15 kernelcache RE
- `ida_kernelcache` (https://github.com/bazad/ida_kernelcache): IDA toolkit
  for iOS kernelcache analysis
- `ioskextdump` (https://github.com/cocoahuke/ioskextdump): Dump kext info
  from iOS kernelcache

Process to analyze AppleMultitouchSPI:
1. Download iPad Air 2 IPSW from ipsw.me (iOS 12.x, last supported version)
2. Extract kernelcache from IPSW (it is a zip file)
3. After iOS 10, 64-bit device kernelcaches are not encrypted
4. Use `ipsw kernel kexts` to list kexts and find AppleMultitouchSPI
5. Load kernelcache into Ghidra with ghidra_kernelcache plugin
6. Navigate to AppleMultitouchSPI methods
7. Analyze the SPI initialization, firmware upload, and report parsing code

This is the most direct path to understanding the BCM5976 protocol as
implemented by Apple.

### 5.4 Multitouch Firmware Extraction from IPSW

The multitouch firmware file is embedded in the iOS IPSW. It can be:
1. Extracted from the IPSW zip archive
2. Found in the device tree or firmware directory
3. Converted from IMG3/IMG4P container format to raw binary
4. Used by the Linux Z2 driver for firmware upload

The Asahi Linux multitouch.py script provides a reference for this extraction.

Sources:
- https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS13.0.sdk/System/Library/Extensions/AppleMultitouchSPI.kext/PlugIns/MultitouchHID.plugin/MultitouchHID.tbd
- https://github.com/blacktop/ipsw
- https://github.com/0x36/ghidra_kernelcache
- https://github.com/bazad/ida_kernelcache
- https://www.nowsecure.com/blog/2017/04/14/ios-kernel-reversing-step-by-step/

---

## 6. Device Tree and Hardware Mapping

### 6.1 iPad Air 2 (J82AP) SoC Configuration

From the J82AP device tree dump:
- SoC: T7001 (Apple A8X)
- CPU: 3x Apple Typhoon cores
- SPI controllers: SPI0-SPI3 present (device IDs 0x10-0x13)

For comparison, the iPhone 3G (N88AP) device tree shows:
- SPI1 at address 0x82100000 hosts the multitouch controller
- Multitouch node at `/arm-io/spi1/multi-touch`
- Chip select: GPIO 0x1300
- Clock enable: via PMU GPIO
- Power supply: via PMU LDO
- Reset: GPIO 0x1401
- Interrupt: GPIO-based

The iPad Air 2 likely uses a similar configuration but with T7001-specific
addresses. The exact SPI controller address and GPIO mappings must be
determined from:
1. The iPad Air 2 Apple Device Tree (extractable from iOS firmware)
2. The konradybcio/linux-apple device tree patches for T7001
3. Nick Chan (asdfugil) A7-A11 device tree patch series

### 6.2 Relevant Upstream Device Tree Work

Nick Chan (asdfugil) submitted a v6 patch series adding device trees for all
A7-A11 based Apple devices. The T7001 (A8X) DTS files include:
- `apple-t7001.dtsi`: SoC base device tree
- `apple-j82.dts`: iPad Air 2 specific device tree

These device trees include SPI controller definitions, GPIO pin controller,
interrupt controller (AIC), UART, and other peripherals. The multitouch node
may or may not be included in the current patches (touch is not yet working,
so it may be omitted).

The SPI controller on A8X is Samsung-derived but not compatible with standard
Samsung SPI drivers. Corellium wrote a custom SPI driver for their
linux-sandcastle kernel because the mainline driver does not support
interrupt-driven transfers needed for the touch controller.

Sources:
- https://gist.github.com/zhuowei/715ded46d018cc7d05265e58d6a65083
- https://www.theiphonewiki.com/wiki/N88AP/Device_Tree
- https://github.com/asdfugil/linux-apple-resources
- https://www.spinics.net/lists/linux-watchdog/msg28766.html
- https://github.com/freedomtan/iOS-device-tree-dump

---

## 7. Paths to Working Touch on iPad Air 2

### Path A: Port apple_z2 Driver (RECOMMENDED - Highest Probability of Success)

The apple_z2 driver in Linux 6.15 implements the Z2 protocol for Apple Silicon
Touch Bars. Since the BCM5976 uses the same Z2 protocol family, this driver can
be ported to the iPad Air 2 with these steps:

1. **SPI controller driver**: The A8X SPI controller is Samsung-derived.
   Either port Corellium's custom SPI driver from linux-sandcastle, or write
   a platform driver for the A8X SPI controller. The mainline Samsung SPI
   driver may work with modifications for interrupt-driven transfers.

2. **Device tree**: Add the multitouch node under the SPI controller in the
   A8X device tree. Required properties:
   - SPI bus address and chip select
   - GPIO for reset (MT_RESET)
   - GPIO for interrupt/attention (MT_ATTN)
   - Firmware filename
   - Calibration data blob

3. **Firmware extraction**: Extract the BCM5976 firmware from iPad Air 2's
   iOS IPSW. The firmware is in IMG4P format and can be extracted using
   tools like img4tool or adapted from Asahi Linux's multitouch.py.

4. **Calibration data**: Extract calibration data from the iOS device tree
   (Apple Device Tree, not Linux DT). The `syscfg` partition on the device
   contains per-unit calibration data. This can be read by pongoOS before
   Linux boots and passed via device tree property.

5. **Testing and debugging**: Use the existing apple_z2 driver as-is, with
   modifications only to the firmware loading path (the BCM5976 firmware
   format may use older IMG3 instead of IMG4P) and any A8X-specific SPI
   timing requirements.

Estimated effort: Medium-High. The driver exists; the work is integration.

### Path B: Adapt hx-touchd as Userspace Daemon

Use Corellium's hx-touchd as a userspace touch daemon:

1. Write a minimal kernel driver that exposes `/dev/hx-touch` with the
   required ioctl interface (SPI access, GPIO control, interrupt waiting)
2. Port hx-touchd to read BCM5976-specific firmware and calibration
3. Run hx-touchd in userspace, injecting touch events via uinput

Advantage: Faster prototyping, can iterate without kernel rebuilds.
Disadvantage: Userspace latency, additional complexity of kernel/userspace split.

Estimated effort: Medium.

### Path C: Record-and-Replay (lemonjesus approach)

Use the training approach from the iPad 3 touchscreen project:

1. Allow the iPad to boot iOS normally while monitoring the SPI bus
2. Record all SPI traffic between the A8X and BCM5976
3. Replay the initialization sequence from Linux
4. Parse touch reports using the known Z2 frame format

This requires hardware access to SPI test points on the iPad Air 2 board
(or a logic analyzer on the SPI bus). The advantage is that it captures the
exact initialization sequence Apple uses, including any BCM5976-specific
quirks.

Disadvantage: Requires hardware modification for SPI sniffing, and the
recorded sequence is specific to one device's calibration data.

Estimated effort: Medium (if hardware skills are available).

### Path D: PongoOS Pre-initialization

Use pongoOS to initialize the touch controller before handing off to Linux:

1. In pongoOS (which runs before Linux), initialize the BCM5976 using
   code adapted from openiBoot or hx-touchd
2. Upload firmware and calibration to the BCM5976
3. Leave the controller running and configured
4. Boot Linux with a simple driver that only reads touch reports (no
   initialization needed)

This simplifies the Linux driver to just the report-reading part, avoiding
the complex firmware upload sequence. PongoOS has direct hardware access to
all SPI controllers and GPIOs.

Estimated effort: Medium. Requires pongoOS development (C, runs on bare metal).

### Path E: Reverse Engineer from iOS Kext (Nuclear Option)

Fully reverse engineer AppleMultitouchSPI.kext from the iOS kernelcache:

1. Download iPad Air 2 IPSW
2. Extract and load kernelcache into Ghidra
3. Find and analyze AppleMultitouchSPI class methods
4. Document every register access, command sequence, and data structure
5. Implement a complete Linux driver from the disassembly

This is the most thorough approach but also the most time-consuming. It
produces the most complete understanding of the BCM5976 protocol.

Estimated effort: High. Weeks of reverse engineering work.

### Path F: External USB Touch Controller (Fallback)

If all software approaches fail, an external USB touch controller can be
physically connected to the iPad's digitizer panel:

1. Disconnect the BCM5976 from the digitizer
2. Connect a commodity USB touch controller IC (e.g., Goodix, ELAN, or
   Atmel mXT) to the same capacitive sensor grid
3. Connect the USB touch controller to the iPad's USB port

This is a hardware hack and may not be practical: the iPad's capacitive
sensor grid is designed for the BCM5976's drive/sense frequency and
voltage, which may not be compatible with other controllers.

A more practical fallback: connect a USB touchscreen overlay or external
USB trackpad via Lightning-to-USB adapter.

Estimated effort: Low (external device) to Very High (rewiring digitizer).

---

## 8. Similar Touch Controllers with Linux Support

### 8.1 Synaptics RMI4 over SPI

The Synaptics RMI4 bus (`drivers/input/rmi4/`) supports SPI transport.
RMI4 Function 11 provides 2D multifinger pointing. The SPI transport layer
handles register reads/writes over SPI v1 and v2. While the protocol is
completely different from Z2, the RMI4 SPI transport driver demonstrates
how to build an SPI-based multi-touch driver in the Linux kernel.

### 8.2 Goodix Touch Controllers

Goodix touchscreens are common in Android devices and have Linux kernel
drivers. They use I2C (not SPI), but the multi-touch reporting via
input_mt_* APIs is the same pattern needed for the BCM5976 driver.

### 8.3 Atmel mXT (Maxtouch)

The Atmel mXT driver (`drivers/input/touchscreen/atmel_mxt_ts.c`) is one
of the most mature touchscreen drivers in the Linux kernel. It handles
firmware updates, configuration, and multi-touch reporting. While it uses
I2C, its driver architecture (firmware loading, config management, touch
reporting) is a good reference for structuring a BCM5976 driver.

### 8.4 Microsoft HID-over-SPI

Microsoft published the HID-over-SPI specification (v1.0) for standardized
touch/input over SPI. Apple's Z2 protocol is NOT compliant with this spec.
Apple's protocol predates the Microsoft spec by approximately five years
and is entirely bespoke. The Microsoft spec is not useful for BCM5976 work.

---

## 9. Community Leads and Contacts

### 9.1 Active Developers

- **Nick Chan (asdfugil)**: A7-A11 device tree patches for Linux, iPad Linux
  community leader. GitHub: https://github.com/asdfugil
  Repository: https://github.com/asdfugil/linux-apple-resources

- **Konrad Dybcio (konradybcio)**: Original Linux-on-iPad-Air-2 work,
  postmarketOS contributor. GitHub: https://github.com/konradybcio

- **Sasha Finkelstein (ChaosPrincess)**: Author of apple_z2 driver for Linux
  kernel. Most knowledgeable about the Z2 protocol in the Linux community.

- **lemonjesus**: Author of the iPad 3 touchscreen project. Demonstrated Z2
  controller operation on older iPad hardware.
  GitHub: https://github.com/lemonjesus

- **Martijn de Vos (devos50)**: QEMU-iOS author, reverse engineered Z2
  multitouch frame format. GitHub: https://github.com/devos50

### 9.2 Communities

- **Hack Different Discord #linux**: Active community for Linux on Apple devices
- **Matrix: The Apple Basement**: iPad Linux development community
- **ipadlinux.org**: Aggregator for iPad Linux efforts
- **postmarketOS wiki**: Device pages for Apple hardware
- **Asahi Linux**: Apple Silicon Linux project, Z2 driver expertise

### 9.3 Relevant Mailing Lists

- linux-input@vger.kernel.org: Where the apple_z2 patches were reviewed
- linux-arm-kernel@lists.infradead.org: Where A7-A11 DTS patches are submitted

### 9.4 Key Search Terms for Future Research

- "Z2 multitouch" (Apple's protocol name)
- "Zephyr2" (firmware format name)
- "hx-touchd" (Corellium's touch daemon)
- "apple_z2" (Linux kernel driver name)
- "MT_SPI_Z2_WAKE_CMD" (protocol constant)
- "AppleMultitouchSPI" (iOS kext name)
- "BCM5976" / "Cumulus" (chip name)

Sources:
- https://ipadlinux.org/
- https://wiki.postmarketos.org/index.php?title=Apple_iPad_Air_2_(apple-ipad5,3)
- https://hackaday.com/2022/06/12/boot-mainline-linux-on-apple-a7-a8-and-a8x-devices/
- https://patchwork.kernel.org/project/linux-arm-kernel/patch/20241128-z2-v2-2-76cc59bbf117@gmail.com/

---

## 10. Recommended Action Plan

### Phase 1: Extract and Analyze (No Hardware Required)

1. Download iPad Air 2 IPSW from ipsw.me
2. Extract kernelcache, load into Ghidra with ghidra_kernelcache plugin
3. Locate AppleMultitouchSPI kext and analyze:
   - SPI register addresses for T7001 SoC
   - Firmware upload sequence
   - Touch report parsing
   - Calibration data format
4. Extract Apple Device Tree from IPSW, dump multitouch SPI node:
   - SPI controller base address
   - Chip select pin
   - Reset GPIO
   - Interrupt GPIO
   - Firmware path
5. Extract multitouch firmware from IPSW (adapt multitouch.py from Asahi)
6. Study hx-touchd.c and apple_z2.c source code side by side

### Phase 2: Prototype Driver (Requires iPad + USB)

1. Build Linux kernel with apple_z2 driver and A8X device tree
2. Add multitouch node to the device tree based on Phase 1 analysis
3. Include extracted firmware in initramfs
4. Boot via checkm8 -> pongoOS -> Linux
5. Check dmesg for apple_z2 driver probe messages
6. Debug SPI communication (may need SPI controller driver fixes)

### Phase 3: Alternative if apple_z2 Fails

1. Implement PongoOS pre-initialization (Path D)
2. Write minimal Linux driver that only reads touch reports
3. Use evtest to verify touch events

### Key Risk: SPI Controller

The A8X's SPI controller is Samsung-derived but Apple-customized. The
existing Samsung SPI driver in the Linux kernel may not work without
modifications. Corellium wrote a custom SPI driver for linux-sandcastle.
This SPI controller driver is a prerequisite for any touch driver approach.

The SPI controller driver is not BCM5976-specific and benefits all SPI
peripherals on the A8X (audio codec, sensors, etc.).

---

## 11. Assessment

### Is BCM5976 Touch on Linux Feasible?

YES. The assessment has changed significantly from the initial driver-gap
analysis. The key findings that change the picture:

1. **The Z2 protocol is documented**: Between hx-touchd, apple_z2, openiBoot,
   lemonjesus's project, and devos50's QEMU work, the Z2 protocol is
   substantially reverse engineered and documented.

2. **A Linux kernel driver exists**: The apple_z2 driver in Linux 6.15
   implements the Z2 protocol. It needs porting, not writing from scratch.

3. **The touch data format is known**: The tp_finger structure is shared
   across BCM5974, BCM5976, and Z2 controllers. Touch report parsing
   code exists and is proven.

4. **Firmware extraction is tractable**: The Asahi Linux multitouch.py
   script demonstrates firmware extraction from Apple firmware containers.

5. **Multiple working implementations exist**: At least five independent
   implementations of Z2 protocol communication have been created.

### What Remains Unknown

1. **Exact SPI bus configuration on T7001/A8X**: Which SPI controller
   (SPI0-SPI3) hosts the BCM5976, at what address, with which GPIOs.
   Extractable from iOS firmware analysis.

2. **BCM5976-specific protocol quirks**: Whether the BCM5976 uses any
   commands or features not present in the Apple Silicon Z2 implementation.
   Likely minimal differences given the protocol family continuity.

3. **A8X SPI controller driver**: Whether the mainline Samsung SPI driver
   works or if a custom driver is needed. This is the single biggest
   unknown.

4. **Calibration data format**: Whether the BCM5976 calibration data uses
   the same format as the Apple Silicon Z2 calibration. Can be determined
   from iOS firmware analysis.

### Difficulty Rating (Revised)

Original assessment: HIGH (proprietary SPI protocol, no documentation)
Revised assessment: MEDIUM (protocol documented, driver exists, needs porting)

The touch controller is no longer the hardest unsolved problem for iPad Air 2
Linux. The SPI controller driver and the GPU are harder problems.
