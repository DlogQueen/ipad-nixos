# Phase 0: Research & Feasibility — Design

## Goal

Determine whether booting NixOS on iPad Air 2 (A8X, 2014) via checkm8 is feasible. Produce 5 research documents that map the full landscape, hardware, boot chain, driver gaps, and a go/no-go assessment.

## Target Hardware

iPad Air 2: A8X SoC (3x Typhoon ARM64 cores, 2GB RAM, PowerVR GXA6850 GPU). Exploitable via checkm8 (permanent bootrom vulnerability, A5-A11).

## Deliverables

### 1. `research/landscape.md` — Existing Projects

Per project (checkm8, pongoOS, Project Sandcastle, postmarketOS, Asahi Linux, Corellium, linux-on-iphone):
- Purpose, current status, last activity
- Supported hardware
- Reusable components for iPad Air 2
- License and availability

### 2. `research/hardware.md` — iPad Air 2 Hardware

- A8X SoC architecture (CPU, GPU, memory controller)
- Peripheral chip identification (display, touch, WiFi/BT, audio, PMU)
- Memory map and MMIO regions from existing device trees
- Comparison with hardware that has Linux support

### 3. `research/boot-chain.md` — Boot Path

- checkm8 exploit mechanics (DFU → payload)
- pongoOS capabilities (USB, shell, module loading, kernel handoff)
- Linux kernel loading and device tree passing
- initramfs requirements
- Step-by-step boot sequence for iPad Air 2

### 4. `research/driver-gap.md` — Driver Status Matrix

Per subsystem (display, touch, WiFi, GPU, audio, battery, USB, BT, sensors):
- Chip/controller identification
- Existing Linux driver and status (working / partial / none)
- Blockers and effort estimate

### 5. `research/feasibility.md` — Final Assessment

- Go/no-go per milestone (console, framebuffer, touch, WiFi, GPU)
- Critical path and risks
- Recommended roadmap
- Honest difficulty assessment

## Method

Web research for current project status, GitHub activity, technical writeups. Source code inspection only where web research leaves gaps. All findings cited.

## Format

Markdown, factual, present tense, imperative mood. No hype or temporal markers.
