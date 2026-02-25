# Touch Controller Reverse Engineering Research: BCM5976 on iPad Air 2

Research into HID-over-SPI implementations, Apple's Z2 touch protocol, and practical
reverse engineering approaches for the Broadcom BCM5976 touch controller.
Conducted February 2026.

---

## 1. HID-over-SPI Standard (Microsoft HIDSPI)

Microsoft published the HID Over SPI Protocol Specification v1.0 on July 15, 2024. It
defines how HID-class devices communicate over SPI.

### Architecture

- Windows provides `HIDSPI.sys`, a KMDF-based HID miniport driver
- Device discovery via ACPI (compatible ID match), not plug-and-play enumeration
- SPI controller driver exposes SPB IOCTL interface for read/write
- GPIO controller delivers interrupts from device (attention line)
- A resource hub proxies connections between HIDSPI driver and SPI controller

### Protocol Characteristics

- Descriptor-based: device reports its capabilities via HID descriptors
- Interrupt-driven: device asserts GPIO when it has data
- Host reads from device via SPI when interrupt fires
- Uses standard HID report format over SPI transport
- SPI-only (no I2C, SMBUS, or other low-power buses)

### HIDSPICx Class Extension

For hardware-accelerated implementations, Windows provides HIDSPICx, a class extension
that allows custom SPI HWA controller drivers without SpbCx. Vendors provide a client
driver implementing the interface defined by the class extension.

### Relevance to Apple

Apple does NOT use the Microsoft HIDSPI standard. Apple's touch protocol predates the
HIDSPI specification by many years (BCM5976 dates to 2012, HIDSPI spec is 2024). Apple
uses a proprietary protocol called "Z2" which is structurally different from HIDSPI:

- Z2 uses a custom frame format with 16-byte command packets
- Z2 has its own checksum scheme (not CRC-16 like many HID-over-SPI implementations)
- Z2 requires device-specific firmware upload during initialization
- Z2 touch reports use Apple-proprietary field layouts, not standard HID report descriptors

However, the high-level pattern is similar: SPI bus + GPIO interrupt line + command/response
protocol + touch report data. Understanding HIDSPI helps frame what the Z2 protocol is doing,
even though the specifics differ.

Sources:
- https://learn.microsoft.com/en-us/windows-hardware/drivers/hid/architecture-and-overview-for-spi
- https://learn.microsoft.com/en-us/windows-hardware/drivers/hid/hid-over-spi
- https://www.microsoft.com/en-my/download/details.aspx?id=103325

---

## 2. Existing SPI Touch Drivers in Linux

### SPI Touchscreen Drivers in the Kernel

The Linux kernel (`drivers/input/touchscreen/`) contains these SPI-based drivers:

| Driver | File | Chip | Protocol |
|--------|------|------|----------|
| AD7879 SPI | ad7879-spi.c | Analog Devices AD7879 | Command/response |
| Cypress CYTTSP | cyttsp_spi.c | Cypress TrueTouch | Command/response |
| Goodix Berlin SPI | goodix_berlin_spi.c | Goodix GT9897/GT9916 | HID-like over SPI |
| Surface 3 SPI | surface3_spi.c | Unknown (Microsoft) | Custom packets |
| ADS7846 | ads7846.c | TI ADS7846 | ADC readout |
| Apple Z2 | apple_z2.c | Apple Z2 controllers | Z2 protocol (NEW in 6.15) |

Additionally in `drivers/input/keyboard/`:
| Driver | File | Chip | Protocol |
|--------|------|------|----------|
| Apple SPI | applespi.c | MacBook keyboard/trackpad | Custom packets |

And in `drivers/hid/`:
| Driver | File | Chip | Protocol |
|--------|------|------|----------|
| Goodix HID-over-SPI | hid-goodix-spi.c | Goodix GT7986U | Custom HID-over-SPI |

### Common SPI Touch Protocol Pattern

All SPI touch drivers follow a similar architecture:

1. **Interrupt fires** (GPIO attention line goes low/high)
2. **Host sends read command** via SPI (often a fixed-size command packet)
3. **Device responds** with touch data (variable-length response)
4. **Driver parses** finger count, coordinates, pressure, etc.
5. **Driver reports** to Linux input subsystem via `input_report_abs()` / `input_mt_report_slot_state()`

### Surface 3 SPI Driver (Reference Implementation)

The Surface 3 SPI driver (`surface3_spi.c`) is a good reference for Apple Z2-like protocols:

```
Packet size: 264 bytes fixed
SPI mode: MODE_0 (CPOL=0, CPHA=0)
Word size: 8 bits
Protocol header: 0xff 0xff 0xff 0xff 0xa5 0x5a 0xe7 0x7e 0x01
Touch marker: 0xd2
Pen marker: 0x16
Max 13 fingers tracked
```

Per-finger data structure (14 bytes):
```c
struct surface3_ts_data_finger {
    u8 status;
    __le16 tracking_id;
    __le16 x;        // range 0-9600
    __le16 cx;
    __le16 y;        // range 0-7200
    __le16 cy;
    __le16 width;    // range 0-1024
    __le16 height;   // range 0-1024
    u32 padding;
} __packed;
```

### Apple SPI Keyboard/Trackpad Driver (applespi.c)

This driver supports MacBook 12" (2015+) and MacBook Pro 2016-2018 keyboards and trackpads
over SPI. The protocol was reverse engineered. Key details:

**Packet format (256 bytes fixed):**
```c
struct spi_packet {
    u8 flags;           // 0x40=write, 0x20=read
    u8 device;          // 0x01=keyboard, 0x02=touchpad, 0xd0=info
    __le16 offset;      // multi-packet message offset
    __le16 remaining;   // bytes remaining in subsequent packets
    __le16 length;      // valid data length in this packet
    u8 data[246];       // payload
    __le16 crc16;       // CRC-16 checksum
};
```

**Message types:**
- 0x0110: Keyboard event data
- 0x0210: Touchpad event data
- 0x0252: Multitouch initialization
- 0x1020: Touchpad info query

**Trackpad finger structure (identical to BCM5974):**
```c
struct tp_finger {
    __le16 origin, abs_x, abs_y, rel_x, rel_y;
    __le16 tool_major, tool_minor, orientation;
    __le16 touch_major, touch_minor, unused[2];
    __le16 pressure, multi, crc16;
};
```

This is significant: the MacBook SPI trackpad uses the same `tp_finger` structure as the
USB BCM5974 driver. The finger data format appears to be consistent across Broadcom touch
controllers regardless of transport (USB vs SPI).

### Goodix HID-over-SPI (hid-goodix-spi.c)

The Goodix GT7986U is a modern touchscreen that wraps HID reports in a custom SPI transport.
Key design note from the patch submission: the device is "not compatible with Microsoft's
HID-over-SPI protocol and therefore needs to implement its own flavor." This confirms that
even among modern chips, HID-over-SPI is not standardized across vendors.

Sources:
- https://github.com/torvalds/linux/blob/master/drivers/input/touchscreen/surface3_spi.c
- https://github.com/torvalds/linux/blob/master/drivers/input/keyboard/applespi.c
- https://github.com/torvalds/linux/blob/master/drivers/input/mouse/bcm5974.c
- https://patchwork.kernel.org/project/linux-input/patch/20240607133709.3518-1-charles.goodix@gmail.com/

---

## 3. Apple Z2 Protocol (Critical Finding)

The Apple Z2 touchscreen driver was merged into Linux 6.15. This is the single most
important finding of this research: there is now an open-source implementation of Apple's
touch protocol in the mainline kernel.

### What is Z2?

Z2 is Apple's protocol for SPI-based touchscreens and Touch Bars. According to the kernel
patch authors (Sasha Finkelstein and Janne Grunau from the Asahi Linux project):

"Z2 is Apple's primarily [sic] protocol for the touchscreen on mobile Apple devices and
for the Touch Bar with their M-series Apple Silicon devices."

This means the Z2 protocol is used on:
- M-series MacBook Touch Bars
- Mobile Apple devices (iPhones, iPads) with SPI touchscreens

### Z2 Protocol Details

#### Command Structure

The Z2 read interrupt command is a 16-byte packet:
```c
struct apple_z2_read_interrupt_cmd {
    u8 cmd;             // APPLE_Z2_CMD_READ_INTERRUPT_DATA = 0xEB
    u8 counter;         // toggles 0/1 (parity bit)
    u8 unused[12];      // padding
    __le16 checksum;    // sum: cmd + 1 + counter
};
```

#### Key Constants

```c
#define APPLE_Z2_CMD_READ_INTERRUPT_DATA  0xEB
#define APPLE_Z2_FW_MAGIC                 0x5746325A  // "Z2FW" in little-endian
#define APPLE_Z2_HBPP_CMD_BLOB            0x3001
#define APPLE_Z2_NUM_FINGERS_OFFSET       16
#define APPLE_Z2_FINGER_DATA_OFFSET       24
#define APPLE_Z2_TOUCH_STARTED            3
#define APPLE_Z2_TOUCH_MOVED              4
```

#### SPI Transaction Flow

1. Device asserts interrupt on GPIO line
2. Host sends 16-byte read command (0xEB + counter + padding + checksum)
3. First SPI exchange returns packet length
4. Second SPI exchange reads full touch data packet
5. Counter toggles between 0 and 1 for each transaction

#### Finger Data Structure (32 bytes per finger)

```c
struct apple_z2_finger {
    u8 finger;           // finger ID
    u8 state;            // 3=started, 4=moved
    __le16 unknown2;
    __le16 abs_x;        // absolute X coordinate
    __le16 abs_y;        // absolute Y coordinate
    __le16 rel_x;        // relative X delta
    __le16 rel_y;        // relative Y delta
    __le16 tool_major;   // major axis of tool contact area
    __le16 tool_minor;   // minor axis of tool contact area
    __le16 orientation;  // contact angle
    __le16 touch_major;  // major axis of touch area
    __le16 touch_minor;  // minor axis of touch area
    __le16 unused[2];
    __le16 pressure;
    __le16 multi;
};
```

This structure is nearly identical to the BCM5974 (USB MacBook trackpad) and applespi
(SPI MacBook trackpad) finger structures. The field ordering, sizes, and semantics match.

#### Firmware Loading

Three firmware load command types:
```c
LOAD_COMMAND_INIT_PAYLOAD     = 0  // 8-bit SPI transfers
LOAD_COMMAND_SEND_BLOB        = 1  // 16-bit SPI transfers
LOAD_COMMAND_SEND_CALIBRATION = 2  // device-specific calibration data
```

Firmware container format:
- Magic: "Z2FW" (0x5746325A)
- Version field: uint32 (value 1)
- Followed by load commands, each with command ID + length prefix

HBPP blob header:
```c
struct apple_z2_hbpp_blob_hdr {
    __le16 cmd;       // 0x3001
    __le16 len;       // length in words
    __le32 addr;      // target address
    __le16 checksum;  // sum of header bytes 2-5
};
```

Each blob payload has a 4-byte trailing checksum (sum of all payload bytes).

#### Calibration

Calibration data is stored as a device tree property `apple,z2-cal-blob` (max 4096 bytes).
The calibration blob is sent during firmware loading as `LOAD_COMMAND_SEND_CALIBRATION`.

#### Device Tree Bindings

```
compatible = "apple,z2-multitouch" | "apple,z2-touchbar"
spi-max-frequency = <11500000>   // 11.5 MHz
interrupts: GPIO interrupt line
reset-gpios: reset line
firmware-name: path to firmware binary
touchscreen-size-x, touchscreen-size-y: screen dimensions
cs-gpios: optional, for devices where hardware CS is broken
```

### Z2 Protocol Applicability to iPad Air 2

The Z2 protocol is described as the primary touch protocol for "mobile Apple devices."
The BCM5976 in iPad Air 2 is an older chip (2012-2017 era), while the Z2 driver targets
M-series Touch Bars (2020+) and presumably newer iOS touchscreens.

Key question: does the BCM5976 use Z2, or an older protocol?

Evidence that BCM5976 uses Z2 (or a predecessor):
1. The hx-touchd daemon from Project Sandcastle (iPhone 7, 2016) uses commands in the
   0xE1-0xEE range, which matches the Z2 command structure
2. The lemonjesus iPad 3 project describes the "Z2 subsystem" by name
3. The finger data format is consistent across BCM5974 (USB, 2008), applespi (SPI, 2015),
   and apple_z2 (SPI, 2024)

Evidence of possible differences:
1. The BCM5976 is a Broadcom chip; newer Apple devices may use Apple-designed touch controllers
2. The Z2 driver in Linux targets M-series Touch Bar first; mobile touchscreen DT entries
   are not yet upstream
3. Firmware format may differ between generations

Assessment: the Z2 protocol is very likely the same protocol (or a close ancestor) used by
the BCM5976. The finger data structures are too similar to be coincidental. The iPad Air 2
should be targetable with an adapted version of the apple_z2 driver.

Sources:
- https://patchwork.kernel.org/project/linux-arm-kernel/patch/20241128-z2-v2-2-76cc59bbf117@gmail.com/
- https://lore.kernel.org/lkml/20250112-z2-v3-3-5c0e555d3df1@gmail.com/T/
- https://www.phoronix.com/news/Linux-6.15-Input
- https://github.com/AsahiLinux/asahi-installer/blob/main/asahi_firmware/multitouch.py
- https://asahilinux.org/2025/05/progress-report-6-15/

---

## 4. Project Sandcastle hx-touchd Protocol Details

### Architecture

The hx-touchd daemon from Project Sandcastle (Corellium) implements a userspace touch
driver for iPhone 7. It uses a kernel driver (`/dev/hx-touch`) for SPI access and a
userspace daemon for protocol handling.

### Protocol: Z2 Frame Format

The protocol uses 16-byte fixed-length frames:
- 14 bytes of data
- 2-byte little-endian checksum (sum of first 14 bytes, stored at offset 14-15)
- 1000 microsecond delays between CS assertion/deassertion

### Command Bytes (0xE1-0xEE range)

```c
MT_CMD_LAST           = 0xE1  // sequence terminator
MT_DEV_INFO           = 0xE2  // device information query
MT_REP_INFO           = 0xE3  // report information query
MT_CTRL_WRITE_SHORT   = 0xE4  // short control write
MT_CTRL_WRITE_LONG    = 0xE5  // long control write
MT_CTRL_READ_SHORT    = 0xE6  // short control read
MT_CTRL_READ_LONG     = 0xE7  // long control read
MT_SPI_Z2_WAKE_CMD    = 0xEE  // wake command
```

### IOCTLs (Kernel Interface)

```c
HXT_IOC_RESET      // controller reset
HXT_IOC_SET_CS     // chip select control
HXT_IOC_SETUP_IRQ  // interrupt configuration
HXT_IOC_WAIT_IRQ   // wait for interrupt
HXT_IOC_READY      // signal operational readiness
HXT_IOC_METRICS    // set screen boundary configuration
```

### Firmware Loading

- Firmware loaded from .mtprops files (device-specific)
- Configuration extracted from syscfg partition (device NVMe)
- Data transferred in 16384-byte chunks with frame wrapping
- Two firmware types supported (mt_type == 1 or 2)
- Firmware transfer involves acknowledgment when required (MTFW_WRITE_ACK type)

### Screen Metrics (Report 0xD9)

Report 0xD9 contains calibration/boundary data:
```
Offset 8-9:   left coordinate (little-endian 16-bit)
Offset 10:    bottom value
Offset 12-13: right coordinate (little-endian 16-bit)
Offset 14:    top value
```

### Relationship to apple_z2 Kernel Driver

The hx-touchd commands (0xE1-0xEE) operate at a different layer than the apple_z2 driver's
0xEB read command. The hx-touchd commands appear to be the control/management protocol,
while 0xEB is the data read command. Together they form the complete Z2 protocol stack:

- Control plane: 0xE1-0xEE commands (firmware upload, configuration, status queries)
- Data plane: 0xEB interrupt read command (touch event streaming)

Sources:
- https://github.com/corellium/projectsandcastle/tree/master/hx-touchd
- https://deepwiki.com/corellium/projectsandcastle

---

## 5. Broadcom Touch Controller Family

### Evolution

| Chip | Transport | Devices | Linux Driver | Protocol |
|------|-----------|---------|-------------|----------|
| BCM5974 | USB | MacBook Air/Pro 2008-2014 | bcm5974.c | USB HID + custom reports |
| BCM5976 | SPI | iPhone 5-6+, iPad Air 1/2, Mini 1-4 | None | Z2 (SPI) |
| BCM15951 | SPI | iPhone X, XS, XS Max | None | Z2 (SPI, likely) |
| Unknown | SPI | iPhone 7 (A10) | hx-touchd (userspace) | Z2 (SPI) |
| Unknown | SPI | M-series Touch Bar | apple_z2.c | Z2 (SPI) |

### BCM5974 USB Protocol (Well Documented)

The Linux kernel BCM5974 driver provides the most complete documentation of Broadcom's
touch report format. Four hardware generations exist:

```
TYPE1: header 26B, finger 28B (MacBook Air 2008)
TYPE2: header 30B, finger 28B (MacBook Pro 2008-2009)
TYPE3: header 38B, finger 28B (MacBook Pro 2010+)
TYPE4: header 46B, finger 30B (Force Touch trackpads)
```

The `tp_finger` structure in BCM5974 is structurally identical to the finger structure in
apple_z2:
```c
struct tp_finger {
    __le16 origin;
    __le16 abs_x, abs_y;
    __le16 rel_x, rel_y;
    __le16 tool_major, tool_minor;
    __le16 orientation;
    __le16 touch_major, touch_minor;
    __le16 unused[2];
    __le16 pressure;
    __le16 multi;
};
```

This confirms a Broadcom touch controller protocol family: the finger report format is
consistent across USB (BCM5974) and SPI (Z2) transports, spanning 2008 through 2024.

### BCM5976 Specifics

- Package: 63-pin BGA, Apple codename "Cumulus"
- Board designations: U12 (iPhone 5/5S), U2401 (iPhone 6), U4100/U4150 (iPad Air 2)
- No public datasheet (confirmed dead end via iFixit community)
- TechInsights has die analysis available (paid, $5000+ range)
- The chip is no longer in production (superseded by BCM15951 and Apple-designed controllers)

### BCM15951

Used in iPhone X and later. TechInsights has a basic functional analysis available (paid).
The BCM15951 likely uses the same Z2 protocol, given that:
1. Project Sandcastle's hx-touchd works on iPhone 7 (which has a controller between BCM5976 and BCM15951)
2. The Z2 driver in Linux 6.15 works with M-series Touch Bars
3. The finger data format is consistent across all known implementations

Sources:
- https://docs.kernel.org/input/devices/bcm5974.html
- https://github.com/torvalds/linux/blob/master/drivers/input/mouse/bcm5974.c
- https://www.techinsights.com/products/far-1711-902
- https://www.reverse-costing.com/teardown-notes/broadcom-bcm5976-iphone-6s/

---

## 6. The lemonjesus iPad Touch Screen Project (Critical Finding)

A project by "lemonjesus" demonstrates a working iPad 3 touchscreen driven by a Raspberry
Pi Pico, using the Z2 protocol. This is the second most important finding of this research.

### Architecture

```
iPad 3 digitizer panel
    |
    SPI bus (MOSI, MISO, CLK, CS)
    + MT_ATTN (interrupt)
    + MT_RESET (reset line)
    |
Raspberry Pi Pico (RP2040)
    |
    USB HID Multitouch
    |
Host PC (Windows/Linux)
```

### How It Works

**Training phase:**
1. iPad boots into iOS normally (A5X SoC controls the touch subsystem)
2. Pico passively monitors the SPI bus
3. Pico records ALL messages sent to the "Z2 subsystem" during boot
4. Recording finishes when an "execute packet" is sent
5. The complete initialization sequence (firmware + calibration) is saved to Pico flash

**Normal operation:**
1. A5X is held in reset (NPN transistor on reset line)
2. Pico replays the recorded initialization sequence to the Z2 touch controller
3. Touch data arrives on SPI whenever MT_ATTN (interrupt) fires
4. Pico converts touch data to USB HID multitouch reports
5. Host PC receives standard multitouch input (works on Windows/Linux without drivers)

### Hardware Interface

```
SPI MISO, MOSI, CLK, CS  — standard SPI bus to Z2 controller
MT_SELECT                 — selects between boot (training) and normal SPI interface
MT_RESET                  — active-low reset line for Z2 controller
MT_ATTN                   — interrupt signal (touch data available)
I2C_SDA, I2C_SCL          — I2C bus for PMU configuration
A5X_RESET                 — controlled via 2N2222 NPN transistor
```

### PMU Configuration

The PMU must be configured via I2C to deliver 2.8V to the Z2 subsystem. Without this,
the touch controller does not power up. This is critical for standalone operation without
the SoC.

### Key Insight: Replay-Based Initialization

The project avoids full protocol reverse engineering by recording and replaying the iOS
initialization sequence. This approach:
- Works without understanding every protocol detail
- Captures device-specific calibration data
- Requires the iPad to be able to boot iOS at least once for training
- May not be portable across different iPad units if calibration varies per-device

### Applicability to iPad Air 2

The lemonjesus project targets iPad 3 (A5X, 2012). The iPad Air 2 (A8X, 2014) uses the
same BCM5976 touch controller family. The Z2 protocol should be compatible. Key differences:
- Different SPI bus configuration on A8X vs A5X SoC
- Potentially different firmware version
- Different screen dimensions (different calibration data)

For our NixOS project, we could:
1. Use the replay approach for initial bring-up (boot iOS once to capture init sequence)
2. Port to a proper Linux SPI driver once the protocol is verified
3. Use the apple_z2 kernel driver as the driver framework

Sources:
- https://github.com/lemonjesus/ipad-touch-screen
- https://hackaday.com/2026/02/09/upcycling-an-ipad-into-a-touchscreen-display-for-your-pc/

---

## 7. Apple SPI Controller on A8X

### Asahi Linux SPI Controller Driver

The Apple SPI controller driver was submitted for Linux 6.15 (alongside the Z2 driver).
Key technical details:

**Supported SoCs (currently):**
- apple,t8103-spi (M1)
- apple,t8112-spi (M2)
- apple,t6000-spi (M1 Pro/Max/Ultra)
- Fallback: apple,spi

**Register layout:**
```
0x000  Control register
0x004  Configuration register
0x008  Status register
0x00c  Pin control
0x010  TX data
0x020  RX data
0x030  Clock divisor (max 0x7ff)
0x10c  FIFO status
0x150  Shift configuration
```

**Specifications:**
- Clock: calculated from parent clock, slowest refclock 24 MHz
- Modes: CPHA, CPOL, LSB_FIRST supported
- Word size: up to 32 bits
- FIFO-based transfers, IRQ per 8-16 words
- DMA offload coprocessor exists but not yet upstreamed

**A8X Compatibility:**

The Asahi Linux SPI driver notes say: "The hardware shares some register bit definitions
with spi-s3c24xx which suggests it has a shared legacy with Samsung SoCs, but it is too
different to warrant sharing a driver."

A8X (and earlier A-series chips A7-A11) use a Samsung-derived SPI controller. Project
Sandcastle noted for iPhone 7 (A10): "The SPI controller was inspired by Samsung but not
compatible, and the driver in the kernel tree was not designed for interrupt-driven
transfers, so they had to write their own driver."

This means:
- The M-series apple,spi driver may NOT work directly on A8X
- A8X likely needs the Samsung-derived SPI driver with modifications
- Corellium already wrote a custom SPI driver for A10 (not upstreamed)
- The register layout is likely similar but different enough to need a separate driver

The Z2 protocol itself (touch data format, commands) should be the same regardless of
which SPI controller is underneath. The SPI controller is just the transport; the touch
protocol operates at a higher level.

Sources:
- https://lore.kernel.org/linux-arm-kernel/20241106-asahi-spi-v5-0-e81a4f3a8e19@jannau.net/T/
- https://patchew.org/linux/20241101-asahi-spi-v3-0-3b411c5fb8e5@jannau.net/20241101-asahi-spi-v3-1-3b411c5fb8e5@jannau.net/
- https://projectsandcastle.org/history

---

## 8. iOS Touch Stack (for Reverse Engineering)

### Kernel Architecture

The iOS touch input stack consists of:

```
Hardware: BCM5976 (SPI)
    |
Kernel: AppleSPIController.kext        (SPI bus driver)
    |
Kernel: AppleMultitouchSPI.kext        (touch-over-SPI transport)
    |
Kernel: IOHIDFamily                    (HID abstraction layer)
    |
    IOHIDEventSystem
    |    IOHIDService (per-device)
    |    IOHIDDisplay
    |
Userspace: MultitouchSupport.framework (private, touch processing)
    |
Userspace: BackBoardServices.framework (private, event routing)
    |
Userspace: UIKit (public API)
```

### IOHIDFamily

IOHIDFamily provides an abstract interface with HID devices (touchscreen, buttons,
accelerometer, etc.). Two API levels:
- Public: for HID driver writers
- Private: for event processing

IOHIDEventSystem interfaces with the whole HID system, consisting of IOHIDServices and
IOHIDDisplays. Services interface with IOHIDLibPlugin kernel plugin and accept direct
human input.

### Extracting and Analyzing Touch Kexts

**Tool: ipsw (by blacktop)**

```bash
# Extract kernelcache from IPSW
ipsw extract --kernel iPad_Air_2_iOS_xx_Restore.ipsw

# List kernel extensions
ipsw kernel kexts kernelcache.release.ipad

# Extract specific kext
ipsw kernel extract kernelcache.release.ipad \
    -e com.apple.driver.AppleMultitouchSPI \
    --output /tmp/kexts/
```

**Tool: ghidra_kernelcache**

The ghidra_kernelcache framework (by @0x36) automates iOS kernelcache reverse engineering:
- Works on iOS 12/13/14/15 kernelcaches
- Requires iometa (by @s1guza) for C++ class information
- Adds IOKit class virtual tables for lookup
- Provides namespace resolution and symbol propagation

**Approach for touch kext analysis:**
1. Download iPad Air 2 IPSW (iOS 10 or 12 for widest compatibility)
2. Extract kernelcache using ipsw tool
3. Extract AppleMultitouchSPI.kext and AppleSPIController.kext
4. Load into Ghidra with ghidra_kernelcache framework
5. Focus on: initialization sequence, SPI command bytes, report parsing functions,
   firmware upload routines, interrupt handlers
6. Cross-reference with known Z2 protocol constants (0xEB, 0xE1-0xEE, etc.)

Sources:
- https://iphonedev.wiki/IOHIDFamily
- https://github.com/0x36/ghidra_kernelcache
- https://blacktop.github.io/ipsw/docs/guides/kernel/
- https://www.theiphonewiki.com/wiki/Kernelcache

---

## 9. Corellium's Virtual Touch Implementation

### What We Know

Corellium's CHARM hypervisor virtualizes iOS devices including touch input. Their approach
requires implementing the touch controller interface at the MMIO/SPI register level, since
iOS drivers talk to the hardware through specific register sequences.

### CHARM Architecture

CHARM is a type-1 hypervisor built from the ground up for ARM. It:
- Models complex peripherals and chipsets on bare metal ARM servers
- Supports custom device modeling (developer kit available)
- Can attach custom peripheral models to virtual iOS devices

### Implications for Protocol Knowledge

To virtualize touch, Corellium must:
1. Know the exact SPI register interface the touch controller presents
2. Know the firmware upload protocol
3. Know the touch report format
4. Know the initialization sequence iOS expects

Corellium wrote Project Sandcastle's hx-touchd, confirming they have deep knowledge of the
touch protocol. However, they have NOT published a detailed protocol specification.

### What They Have Published

- hx-touchd source code (GPL-2.0) — the most detailed public documentation of the protocol
- Linux-sandcastle kernel (includes SPI driver for iPhone 7)
- The "touch controller is not very complex to interface with" (from their blog)

### Custom Device Modeling SDK

Corellium's developer kit allows creating custom virtual device models. The API supports
UART, I2C, SPI interfaces. This SDK could theoretically be used to study how their touch
model works, but it requires a Corellium subscription.

Sources:
- https://www.corellium.com/custom-device-modeling-corellium
- https://support.corellium.com/environments/charm-sdk
- https://projectsandcastle.org/history

---

## 10. PongoOS as a Development Platform

### Current Capabilities

PongoOS provides:
- USB shell (pongoterm) for interactive commands
- Memory read/write (direct register access)
- Module loading (custom code execution)
- Framebuffer output
- UART serial console
- Device tree parsing for hardware discovery

### What PongoOS Does NOT Have

- No SPI driver (confirmed missing from driver list)
- No touch controller support
- No I2C driver (for PMU configuration)

### Extending PongoOS for Touch RE

To use pongoOS as a touch protocol sniffer/debugger:

1. **Write an SPI driver module for pongoOS**
   - Map the A8X SPI controller registers (discoverable from device tree)
   - Samsung-derived SPI controller, register layout partially known
   - Corellium already did this for their iPhone 7 kernel; code in linux-sandcastle

2. **Configure the SPI bus**
   - Identify which SPI controller instance connects to BCM5976 (from iOS device tree)
   - Set clock speed, mode, word size

3. **Send Z2 protocol commands**
   - Try the known command set (0xE1-0xEE, 0xEB)
   - Observe responses
   - Compare with hx-touchd behavior

4. **Replay captured initialization**
   - Use the lemonjesus approach: let iOS boot, capture the SPI traffic
   - Then replay from pongoOS after subsequent boots

### Alternative: Use pongoOS to Boot Linux Directly

Rather than developing pongoOS SPI drivers, the more practical path is:
1. Use pongoOS as the bootloader (its primary purpose)
2. Boot a Linux kernel with the Z2 touch driver
3. Do all touch driver development in Linux

This is the approach used by all existing Linux-on-iPhone/iPad projects.

Sources:
- https://github.com/checkra1n/PongoOS
- https://deepwiki.com/checkra1n/PongoOS/1-overview

---

## 11. Logic Analyzer / Hardware RE Approach

### Test Points on iPad Air 2

The iPad Air 2 board view is available through ZXW tool (paid subscription, used by
repair technicians). Board number: 820-4550. The board view shows:
- BCM5976 pad locations and signal names
- SPI bus traces (MOSI, MISO, CLK, CS)
- Interrupt/attention line
- Reset line
- Power rails

ZXW allows clicking on any pad to see all connected points on the board. However, ZXW
is a paid tool and the exact test point locations are not publicly documented.

### iPad 3 Touch Panel Investigation (Mike's Mods)

Mike's Mods conducted a physical investigation of the iPad 3 digitizer:
- 40 excitation pins, 30 sense pins, 3 grounds, 1 SHLD pin
- Created a breakout board for the FPC connector
- Conducted electrical testing to identify SPI signals

The iPad Air 2 has a different digitizer connector but the overall architecture is similar.

### Recommended Equipment

**Logic analyzer:**
- Saleae Logic Pro 16: 16 channels, 500 MS/s digital, SPI protocol decoder built in
- Sigrok-compatible analyzers: open-source alternative (DSLogic, fx2lafw devices)
- Minimum requirement: 4 channels (MOSI, MISO, CLK, CS) at 50+ MHz sample rate

**SPI bus speed estimate:**
- The apple_z2 device tree sets `spi-max-frequency = <11500000>` (11.5 MHz)
- The lemonjesus project uses configurable SPI speed via pins.h
- A logic analyzer sampling at 50 MHz should be sufficient for 11.5 MHz SPI

**SPI mode:**
- Likely SPI MODE 0 (CPOL=0, CPHA=0), as used by the Surface 3 SPI touch driver
- Need to verify experimentally

### Practical Sniffing Approach

**Option A: External logic analyzer**
1. Open iPad Air 2 (heat gun to separate glass)
2. Identify SPI test points using ZXW board view
3. Solder 30AWG magnet wire to MOSI, MISO, CLK, CS, ATTN pads
4. Connect to Saleae Logic Pro 16
5. Boot iOS and capture the complete SPI transaction
6. Decode in Saleae software using SPI protocol analyzer
7. Parse captured data against known Z2 protocol format

**Option B: SPI sniffing via Pico (lemonjesus approach)**
1. Follow the lemonjesus project wiring guide
2. Use the training mode to capture all SPI traffic
3. Dump captured data via USB serial for analysis
4. Does not require a separate logic analyzer

**Option C: Software capture (no hardware modification)**
1. Build a custom iOS kernel with SPI tracing
2. Use checkm8 + pongoOS to load the modified kernel
3. Capture SPI transactions from software
4. This requires significant iOS kernel modification skills

Option B is the most practical for our project.

Sources:
- https://www.badcaps.net/forum/troubleshooting-hardware-devices-and-electronics-theory/troubleshooting-laptops-tablets-and-mobile-devices/schematic-requests-only/79143-schematics-boardview-ipad-air-2-820-4550
- http://mikesmods.com/mm-wp/?p=49
- https://github.com/lemonjesus/ipad-touch-screen

---

## 12. Jailbreak Community Touch Research

### IOHIDFamily Event Types

Apple's IOHIDEventTypes.h (open-source) defines touch-related event types:
- IOHIDDigitizerEventRange
- IOHIDDigitizerEventTouch
- IOHIDDigitizerEventPosition
- IOHIDDigitizerEventStop
- IOHIDDigitizerEventPeak
- IOHIDDigitizerEventSwipe

### MultitouchSupport.framework

This private framework provides raw multitouch data access on macOS. Functions include:
- `MTDeviceCreateList()` — enumerate multitouch devices
- Per-device callback registration for raw touch events
- Direct access to finger positions, orientations, pressures

On iOS, this framework handles the pipeline from kernel HID events to UIKit touch objects.

### BackBoardServices.framework

BackBoardServices catalogs private iOS APIs including touch event routing. It serves as
the bridge between IOHIDFamily kernel events and UIKit application-level touch handling.

### Interception Techniques (Jailbroken Device)

With a jailbroken iPad Air 2 (using palera1n, which supports A8X):
1. Load a kernel module that hooks IOHIDFamily event delivery
2. Log all IOHIDDigitizer events including raw finger data
3. Correlate with SPI traffic timing to understand the transform pipeline
4. This provides the high-level touch data format without needing SPI access

However, this only captures post-processing data. The raw SPI protocol is handled by
AppleMultitouchSPI.kext before events reach IOHIDFamily.

### Relevant Jailbreak Tools

- palera1n: supports A8 through A11 devices on iOS 15+ (uses checkm8)
- checkra1n: supports A8 through A11 on iOS 12-14
- Both provide root access and ability to load kernel modules

Sources:
- https://iphonedev.wiki/IOHIDFamily
- https://opensource.apple.com/source/IOHIDFamily/IOHIDFamily-315.7.13/IOHIDFamily/IOHIDEventTypes.h
- https://github.com/palera1n/palera1n
- https://github.com/Kyome22/OpenMultitouchSupport

---

## 13. Firmware Extraction from IPSW

### Multitouch Firmware Location

The Asahi Linux installer's `multitouch.py` reveals how Apple packages touch firmware:

- Source: `Multitouch.im4p` in device-specific firmware directory within IPSW
- Container: img4p format (Apple's signed image format)
- Extracted content: plist XML with embedded binary firmware blobs

### Firmware Format Variants

**Touch Bar firmware:**
```
Magic: "Z2FW" (4 bytes)
Version: uint32 (value 1)
Followed by load commands (init_payload, send_blob, send_calibration)
```

**Trackpad firmware:**
```
Magic: "HIDF" (4 bytes)
Version: 1
Header: 32 bytes
Blob data follows
Serialized as nested dictionaries/arrays with CBOR-like type prefixes
```

### Device Identification Keys

- `C1FD`: trackpad firmware
- `C1FB`: touchbar firmware

### Extraction Procedure for iPad Air 2

1. Download iPad Air 2 IPSW from Apple (ipsw.me)
2. Extract using `ipsw extract --firmware` or manual unzip
3. Locate firmware/all_flash/ or Firmware/ directory
4. Find multitouch-related im4p files
5. Use img4tool or ipsw tool to extract raw firmware payload
6. Analyze firmware format (look for Z2FW or HIDF magic)
7. Compare structure with Asahi Linux's multitouch.py parser

Sources:
- https://github.com/AsahiLinux/asahi-installer/blob/main/asahi_firmware/multitouch.py
- https://blacktop.github.io/ipsw/docs/cli/ipsw/extract/

---

## 14. Recommended Approach for iPad Air 2 Touch

### Phase 1: Software Analysis (No Hardware Needed)

1. Download iPad Air 2 IPSW (iOS 12.5.7 — last supported version)
2. Extract kernelcache, locate AppleMultitouchSPI.kext
3. Analyze in Ghidra with ghidra_kernelcache framework
4. Map the initialization sequence, command bytes, report format
5. Compare with known Z2 protocol constants from apple_z2 and hx-touchd
6. Extract multitouch firmware from IPSW, analyze format

### Phase 2: Protocol Verification (Requires Hardware)

1. Use the lemonjesus approach: connect Raspberry Pi Pico to iPad Air 2 SPI bus
2. Run training mode to capture complete iOS initialization sequence
3. Verify that the captured sequence matches Z2 protocol expectations
4. Test replay initialization and touch data reception
5. Map touch coordinates to screen dimensions

### Phase 3: Linux Driver Development

1. Start with the mainline apple_z2 driver as the base
2. Create an A8X SPI controller driver (based on Corellium's work for A10 + Samsung SPI knowledge)
3. Add iPad Air 2 device tree entries with correct SPI bus, GPIO, and firmware paths
4. Port firmware extraction to work with iPad Air 2 IPSW firmware blobs
5. Test with real hardware
6. Integrate with NixOS kernel configuration

### Key Dependencies

- Apple SPI controller driver for A8X (Samsung-derived, not the M-series apple,spi)
- Touch firmware extraction from IPSW
- Device tree entries for iPad Air 2 SPI + touch controller
- PMU initialization (must provide power to Z2 subsystem)

### Risk Assessment

| Risk | Probability | Mitigation |
|------|------------|------------|
| BCM5976 uses different protocol than Z2 | Low | finger format consistency across 16 years of Apple devices suggests Z2 compatibility |
| A8X SPI controller incompatible with known drivers | Medium | Corellium already solved this for A10; Samsung-derived architecture is documented |
| Firmware format differs from Asahi Linux expectations | Medium | hx-touchd already handles older firmware format; analyze IPSW firmware directly |
| Calibration is per-device | Low | lemonjesus approach captures per-device calibration during training |
| PMU configuration blocks touch controller | Medium | lemonjesus project documents I2C PMU setup; iOS kernel analysis would reveal registers |

Overall: touch driver development is achievable. The apple_z2 driver in Linux 6.15 and
the lemonjesus iPad project provide strong foundations. The main unknowns are the A8X SPI
controller specifics and any BCM5976-specific protocol variations.
