# Syncing Ghosttal and publishing releases

Ghosttal tracks [Ghostty](https://github.com/ghostty-org/ghostty) manually.
Upstream code reaches Ghosttal users only after it is merged, reviewed against
the fork's patch set, tested, and released through Ghosttal's own Sparkle feed.

## Current integration

Ghosttal 0.1.7 integrates the signed Ghostty `v1.4.0` tag (commit
`83fb95624b0439ee660c2679b43b38c8b63769cd`) and the following post-tag fixes:

- `46e9dc9a927b2e7e7cba79e6902c176127dbdf2c` (#14879): reject truncated
  UTF-8 configuration strings instead of panicking.
- `b840b2457cc0f5ee63cb324b3af9bb8e753e512c` (#14876): validate hexadecimal
  letters correctly in Unicode argument escapes.

The build toolchain is Zig 0.17.0. Sparkle remains pinned to 2.9.6. Ghosttal's
own release workflows, identity, configuration layering, motion controls, and
Sparkle feed are retained. Upstream release and repository-maintenance workflows
are intentionally excluded from this integration. The standalone FreeBSD VM
test helpers are retained.

### Validation for 0.1.7

Validated locally on macOS 27.2 with Xcode 27.1 and Zig 0.17.0:

- Complete native Metal/core suite: 4,136 passed, 26 skipped.
- Complete libghostty-vt Zig and C API suites: 6,961 passed, 56 skipped.
- macOS unit suite: 288 passed, one disabled benchmark skipped.
- Focused Metal/fork/parser regressions: 174 passed, three skipped.
- Focused OpenGL regressions: 129 passed.
- ReleaseFast terminal/paste/layout regressions: 209 passed.
- Shipped Bash and Zsh hook regressions: nine passed.
- Native C ABI schema verification and ReleaseSmall WebAssembly build passed.
- SwiftLint strict validation passed across 197 files; tracked Zig formatting,
  shell syntax, workflow YAML, and app version/plist checks passed.
- Universal ReleaseFast/macOS Release preflight passed for both the app and
  DockTilePlugin, with arm64 and x86_64 slices.

Direct app checks passed for startup, typing and Unicode paste/rendering,
forward/backward search, tabs, typed-glyph retention across tab focus changes,
split creation/resizing, command-palette filtering, configuration reload, and
About version/build 0.1.7. The Debug app was closed afterwards.

Automated UI coverage is incomplete: the existing mouse command-palette test
attempted to click an offscreen item, and the suite stalled while setting system
appearance. That run was stopped and was not restarted. Display sleep/wake,
physical monitor hotplug, and runtime testing on older macOS versions remain
manual checks for a maintainer with the corresponding environment.

## Remotes and upstream sync

- `origin` — `git@github.com:ccyisafool/ghosttal.git` (push target)
- `upstream` — `https://github.com/ghostty-org/ghostty` (read-only)

```sh
git fetch upstream --tags
git switch -c sync/<upstream-version> main
git merge <upstream-tag-or-commit>
```

Review conflicts especially carefully in:

- motion rendering: `src/renderer/`, `src/Surface.zig`, and motion shaders;
- configuration overlay loading: `src/config/`;
- macOS branding, bundle identity, icon, and visible strings;
- update configuration in `macos/Ghostty-Info.plist` and the update feature;
- release scripts and workflows.

Internal `Ghostty` module, scheme, terminal-protocol, and compatibility names
remain upstream-compatible. User-facing identity and Ghosttal-owned storage,
downloads, links, and update endpoints must remain Ghosttal-specific.

After every sync, run:

```sh
zig fmt --check .
zig build test -Demit-macos-app=false -Demit-xcframework=false
zig build -Demit-macos-app=false
./macos/build.nu --scheme Ghostty --configuration Debug --action test
./scripts/release-preflight.sh
```

Also launch a Debug app and manually exercise cursor/input motion, Reduce
Motion, the Ghostty-base/Ghosttal-overlay precedence, links, and update checks.

## Automated release

The credential-free `scripts/release-preflight.sh` command first exercises the
ReleaseFast core, unsigned Release app, all app-target versions, and universal
architectures for both the main executable and embedded DockTilePlugin. The
preferred publishing path is `.github/workflows/release-ghosttal.yml`. It verifies the
tagged source, builds a universal app, explicitly signs nested code inside-out,
creates the drag-to-Applications DMG, submits it to Apple notarization, staples
the ticket, publishes the DMG and `SHA256SUMS`, and advances the appcast only
after the release exists.

1. Change every app-target `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` in `macos/Ghostty.xcodeproj/project.pbxproj` to
   `X.Y.Z` and add `## X.Y.Z` to `CHANGELOG.md`.
2. Commit and push the clean, tested change to `main`.
3. Create and push `vX.Y.Z` at that commit.

The tag must be contained in `main`. Releases are serialized, existing assets
must byte-match on retries, and the workflow refuses to move the appcast to an
older version. The signing job uses the protected `release` environment and
these environment secrets:

- `MACOS_CERTIFICATE_P12` and `MACOS_CERTIFICATE_PASSWORD`
- `ASC_API_KEY_P8`, `ASC_API_KEY_ID`, and `ASC_API_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY`

Run `scripts/setup-release-secrets.sh` from a configured Mac to upload them.
The helper never deletes the certificate file supplied by the maintainer.

## Local release

Install Zig 0.17.0, Nushell 0.115.1, Xcode 26, Sparkle 2.9.6 tools, and
`create-dmg`. Prepare and check out the clean tagged commit, then run:

```sh
RELEASE_VERSION=X.Y.Z ./scripts/release-macos.sh
```

Set `SPARKLE_BIN` or `CREATE_DMG` when those tools are not on their default
paths. The script accepts either App Store Connect API-key variables or a
`notarytool` keychain profile (`NOTARY_PROFILE`). It writes the notarized DMG
and `SHA256SUMS` to `dist/` and regenerates `appcast.xml`.

Publish the DMG and checksum before pushing the appcast. Losing the Sparkle
private key prevents installed copies from accepting later updates; back it up
securely and never commit it.
