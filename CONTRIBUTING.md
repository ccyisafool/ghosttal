# Contributing to Ghosttal

Thanks for helping improve Ghosttal. Please search the
[Ghosttal issue tracker](https://github.com/ccyisafool/ghosttal/issues) before
reporting a problem or proposing a change. Include the Ghosttal version, macOS
version, minimal configuration, reproduction steps, and relevant logs in bug
reports.

Ghosttal carries a focused patch set on top of Ghostty. Changes to the terminal
core should preserve upstream behavior; motion, branding, configuration-overlay,
and update-channel changes must preserve Ghosttal's independent identity. Read
[HACKING.md](HACKING.md) for the upstream development guide and
[docs/UPSTREAM-SYNC.md](docs/UPSTREAM-SYNC.md) for fork-specific guidance.

Before submitting a change, run the checks relevant to it:

```sh
zig fmt --check .
zig build test -Dtest-filter=<test-name>
zig build -Demit-macos-app=false
./macos/build.nu --scheme Ghostty --configuration Debug --action test
```

Use `zig build test` before proposing a release or a broad core change. Keep
commits focused, explain user-visible behavior, and add regression coverage for
bug fixes. Never include signing certificates, notarization credentials, or the
Sparkle private key.
