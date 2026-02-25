# iPad NixOS

## Goal

Boot NixOS on old iPads (2011-2017, A5–A11 chips) via checkm8 bootrom exploit, turning e-waste into usable Linux machines.

## Target Hardware

- **Primary target**: iPad Air 2 (A8X, 2014) — 3-core ARM64, 2GB RAM, PowerVR GXA6850 GPU
- **Exploit**: checkm8 (permanent, unpatchable bootrom vulnerability for A5–A11)
- **Boot chain**: checkm8 → pongoOS → Linux kernel → NixOS userland

## Project Structure

```
ipad-nixos/
├── research/          # Phase 0 output — feasibility analysis
│   ├── landscape.md   # Existing projects analysis
│   ├── hardware.md    # iPad Air 2 hardware mapping
│   ├── boot-chain.md  # Full boot path documentation
│   ├── driver-gap.md  # Driver status matrix
│   └── feasibility.md # Final assessment and roadmap
├── boot/              # Boot chain tools and configs
├── kernel/            # Kernel configs and patches
├── nixos/             # NixOS configuration for iPad
├── drivers/           # Custom driver work
├── devenv.nix         # Development environment
├── flake.nix          # Nix flake
└── CLAUDE.md          # This file
```

## Phase 0: Research & Feasibility (autonomous)

Systematic analysis of all existing work. No hardware needed.

1. **Landscape analysis** — deep-dive every existing project:
   - checkm8 / checkra1n (bootrom exploit)
   - pongoOS (pre-boot environment)
   - Project Sandcastle (Android on iPhone)
   - postmarketOS iPhone/iPad support
   - linux-on-iphone GitHub projects
   - Asahi Linux (Apple Silicon Macs — different but relevant techniques)
   - Corellium (commercial iOS virtualization — published research)

2. **Hardware mapping** — iPad Air 2 (A8X) specifics:
   - SoC architecture, memory map, peripheral addresses
   - Device tree sources (from iOS firmware, existing Linux DTs)
   - Display controller, touch controller IC identification
   - WiFi/BT chip (Broadcom model, firmware requirements)
   - GPU (PowerVR GXA6850) — driver status in Mesa/open-source

3. **Boot chain documentation** — full path for iPad specifically:
   - checkm8 exploit execution
   - pongoOS loading and capabilities
   - Linux kernel handoff (how pongoOS passes control)
   - Device tree passing, initramfs requirements
   - What works on iPhone 7 that could transfer to iPad Air 2

4. **Driver gap matrix** — per subsystem:
   - Display: existing framebuffer support, DRM/KMS status
   - Touch: multi-touch controller RE status
   - WiFi: Broadcom chip model, firmware, driver (brcmfmac? wl?)
   - GPU: PowerVR open-source driver status (Mesa PVR?)
   - Audio: codec identification, ALSA/PipeWire feasibility
   - Battery/charging: power management IC
   - USB: host/device mode capabilities
   - Bluetooth: chip, firmware, driver
   - Sensors: accelerometer, ambient light, etc.

5. **NixOS scaffolding** — aarch64 cross-compilation:
   - Base NixOS config targeting A8X
   - Cross-compilation flake setup
   - Minimal rootfs generation

## Phase 1+: Hardware-in-the-loop (interactive)

Requires physical iPad + USB connection to NixOS workstation.

### Feedback Loop Setup

```
NixOS ThinkPad ──USB──► iPad Air 2
     │                      │
     ├─ Claude reads serial ◄─ /dev/ttyACM0 (boot logs)
     ├─ Claude builds kernel
     ├─ Claude prepares flash scripts
     │
     └─ User: runs ./flash.sh, takes photos for display testing
```

### Tools

- `libimobiledevice` — iOS USB communication
- `libirecovery` — recovery/DFU mode
- `picocom` — serial console reader
- `ghidra` / `radare2` — binary analysis
- Nix cross-compilation for aarch64

## Guidelines

- Research first, code second
- Document every finding in research/ directory
- Be honest about blockers and difficulty
- Cross-reference multiple sources before concluding anything
- Focus on iPad Air 2 (A8X) specifically — don't generalize across all iPads
