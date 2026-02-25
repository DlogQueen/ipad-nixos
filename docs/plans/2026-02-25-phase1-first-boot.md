# Phase 1: First Boot — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Boot NixOS on iPad Air 2 via checkm8 → pongoOS → Linux, achieving serial console and framebuffer display output.

**Architecture:** Cross-compile a 16KB-page aarch64 Linux kernel with A8X device tree from the NixOS host. Generate a minimal NixOS initramfs. Script the boot sequence using gaster/Achilles + pongoOS + load_linux.py. The entire system runs from RAM (initramfs).

**Tech Stack:** Nix flake (cross-compilation), Linux kernel 6.13+ (A8X device tree support), pongoOS, gaster/Achilles (checkm8 exploit), Python (load_linux.py)

---

### Task 1: Add aarch64 Cross-Compilation to Flake

**Files:**
- Modify: `flake.nix`

**Step 1: Read existing flake.nix**

Understand current structure (devShell only, x86_64-linux).

**Step 2: Add cross-compilation outputs**

Add `packages.x86_64-linux.kernel` that cross-compiles an aarch64 Linux kernel with 16KB pages. Add `packages.x86_64-linux.initramfs` placeholder.

```nix
# In flake outputs, add:
packages.${system} = {
  kernel = pkgs.pkgsCross.aarch64-multiplatform.callPackage ./kernel/package.nix {};
};
```

**Step 3: Run `nix flake check`**

Verify the flake evaluates without errors.

**Step 4: Commit**

```bash
git add flake.nix
git commit -m "feat: add aarch64 cross-compilation target to flake"
```

---

### Task 2: Create Kernel Package with A8X Config

**Files:**
- Create: `kernel/package.nix`
- Create: `kernel/config-ipad-air2`

**Step 1: Research existing kernel configs**

Check HoolockLinux/docs and linux-apple-resources for the `config_16k` reference config targeting Apple A-series SoCs.

**Step 2: Create kernel/config-ipad-air2**

Minimal kernel config for iPad Air 2. Must include:
- `CONFIG_ARM64=y`
- `CONFIG_ARM64_PAGE_SHIFT=14` (16KB pages)
- `CONFIG_ARCH_APPLE=y`
- `CONFIG_APPLE_AIC=y`
- `CONFIG_FB_SIMPLE=y` or `CONFIG_DRM_SIMPLEDRM=y`
- `CONFIG_SERIAL_SAMSUNG=y` + `CONFIG_SERIAL_SAMSUNG_CONSOLE=y`
- `CONFIG_APPLE_WATCHDOG=y`
- `CONFIG_PINCTRL_APPLE_GPIO=y`
- `CONFIG_BLK_DEV_INITRD=y`
- `CONFIG_USB_DWC2=y`
- `CONFIG_RD_LZMA=y`

**Step 3: Create kernel/package.nix**

Nix derivation that:
- Uses Linux 6.13+ (or latest stable with A8X device tree patches)
- Applies the iPad Air 2 kernel config
- Cross-compiles for aarch64 with 16KB pages
- Outputs: `Image` (raw kernel binary), `Image.lzma` (compressed), DTBs

**Step 4: Test build**

```bash
nix build .#kernel
```

Verify it produces `Image.lzma` and the `apple/j81.dtb` / `apple/j82.dtb` device tree blobs.

**Step 5: Commit**

```bash
git add kernel/
git commit -m "feat: add iPad Air 2 kernel package with 16KB page config"
```

---

### Task 3: Create Minimal NixOS Initramfs

**Files:**
- Create: `nixos/initramfs.nix`
- Modify: `flake.nix` (add initramfs output)

**Step 1: Define minimal NixOS configuration**

A NixOS config that produces the smallest viable initramfs:
- BusyBox or toybox for basic utilities
- getty on tty0 (framebuffer console)
- Networking tools (for future USB Ethernet)
- No systemd initially (use simple init)

**Step 2: Create nixos/initramfs.nix**

NixOS module that builds an initramfs cpio archive.

**Step 3: Add to flake outputs**

```nix
packages.${system}.initramfs = ...;
```

**Step 4: Test build**

```bash
nix build .#initramfs
```

Verify it produces a cpio.lzma archive of reasonable size (<200MB compressed target).

**Step 5: Commit**

```bash
git add nixos/initramfs.nix flake.nix
git commit -m "feat: add minimal NixOS initramfs for iPad Air 2"
```

---

### Task 4: Set Up Boot Chain Tools

**Files:**
- Create: `boot/flash.sh`
- Modify: `devenv.nix` (add boot tools)

**Step 1: Add pongoOS and load_linux.py to devenv**

The boot process needs:
- gaster or Achilles (checkm8 exploit tool)
- pongoOS binary (Pongo.bin)
- load_linux.py (sends kernel/DT/initramfs to pongoOS)
- pyusb (Python USB library for load_linux.py)

**Step 2: Create boot/flash.sh**

Script that automates the full boot sequence:
```bash
#!/usr/bin/env bash
# 1. Wait for iPad in DFU mode
# 2. Run gaster/achilles to exploit and load pongoOS
# 3. Wait for pongoOS USB enumeration
# 4. Run load_linux.py with kernel, DTB, initramfs, cmdline
```

**Step 3: Create dtbpack utility**

pongoOS expects a "dtbpack" container for device tree blobs. Write a small script or use existing tooling to pack the DTB.

**Step 4: Test the script (dry run)**

Verify the script structure, file paths, and tool availability.
Actual hardware testing requires the physical iPad.

**Step 5: Commit**

```bash
git add boot/ devenv.nix
git commit -m "feat: add boot chain tooling and flash script"
```

---

### Task 5: Document the Boot Process

**Files:**
- Create: `boot/README.md`

**Step 1: Write boot instructions**

Document the complete process:
1. Prerequisites (NixOS host, USB cable, iPad Air 2)
2. Enter DFU mode (button sequence)
3. Run `./boot/flash.sh`
4. Expected output at each stage
5. Troubleshooting (exploit failure, kernel panic, no display)

**Step 2: Commit**

```bash
git add boot/README.md
git commit -m "docs: add boot process documentation"
```

---

### Task 6: Integration Test (Requires Hardware)

**This task requires physical iPad Air 2 + USB connection.**

**Step 1: Build all artifacts**

```bash
nix build .#kernel
nix build .#initramfs
```

**Step 2: Connect iPad, enter DFU mode**

**Step 3: Run boot/flash.sh**

**Step 4: Monitor serial output**

```bash
picocom /dev/ttyACM0 -b 115200
```

**Step 5: Verify framebuffer output**

Check if the iPad display shows Linux boot messages or a login prompt.

**Step 6: Debug and iterate**

If boot fails, check serial output for panic messages. Common issues:
- Wrong page size (must be 16KB)
- Missing AIC driver
- Device tree mismatch
- initramfs mount failure

---

## Dependencies

```
Task 1 (flake) ──► Task 2 (kernel) ──► Task 4 (boot tools) ──► Task 6 (hardware test)
                       │
                       ▼
                   Task 3 (initramfs) ──► Task 4
                                              │
                                              ▼
                                         Task 5 (docs)
```

Tasks 2 and 3 can run in parallel after Task 1 is complete.
Task 4 depends on both Task 2 and Task 3.
Task 5 can be written alongside Task 4.
Task 6 requires all previous tasks and physical hardware.
