# Contributing to iPad NixOS

Thank you for your interest in helping bring Linux to old iPads.

## How to Contribute

### Hardware Testing (Most Needed)

If you have an iPad with an A7–A11 chip (2013–2017), your hardware reports are extremely valuable.

1. Follow the [Quick Start](#quick-start) in the README to build and boot
2. Report what works and what doesn't in a GitHub Issue using the "Hardware Report" template
3. Include: iPad model, iOS version, board ID, boot log (serial or photo of screen)

### Code Contributions

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Make your changes
4. Test: `nix flake check` and `nix build .#kernel` / `nix build .#initramfs`
5. Commit with descriptive messages
6. Open a Pull Request

### What to Work On

Check the [Issues](https://github.com/YOUR_USER/ipad-nixos/issues) tab. Priority areas:

| Area | Difficulty | Impact |
|------|-----------|--------|
| Test on different iPad models | Easy (needs hardware) | High |
| Document WiFi firmware extraction | Medium | High |
| Fix/improve device trees | Medium | High |
| Debug touch driver on hardware | Medium-Hard | High |
| Add NixOS GUI (Wayland compositor) | Medium | Medium |
| PowerVR GPU driver work | Very Hard | Very High |
| Bluetooth audio support | Hard | Medium |
| Battery monitoring | Medium | Low |

### Coding Standards

- **Nix**: follow nixpkgs conventions. Use `nix fmt` if available
- **Shell scripts**: `set -euo pipefail`, shellcheck clean
- **Documentation**: factual, technical, present tense. No hyperbole
- **Commits**: imperative mood, explain "why" not "what"

### Research Contributions

The `research/` directory documents hardware and driver status. If you discover new information:

1. Update the relevant file (don't create new ones unless covering a new topic)
2. Include sources and links
3. Cross-reference with existing documents
4. Be specific about which iPad model your findings apply to

### Device Tree Contributions

Device trees are critical for each iPad variant. If you can improve a DTB:

1. DTB sources are in the upstream Linux kernel at `arch/arm64/boot/dts/apple/`
2. Test with your specific hardware
3. Document which peripherals work with the new DTB
4. Submit patches upstream to the Linux kernel (preferred) or here

## Reporting Issues

Use GitHub Issues. Include:

- **iPad model** (e.g., iPad Air 2 WiFi, A1566)
- **Board ID** (e.g., J81) — shown in Settings > General > About
- **Build host** (OS, architecture)
- **What you tried** (exact commands)
- **What happened** (error messages, boot log, photos)
- **What you expected**

## Communication

- GitHub Issues for bugs and feature requests
- GitHub Discussions for questions and ideas
- Pull Requests for code contributions

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
