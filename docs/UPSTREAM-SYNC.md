# Syncing Ghosttal and publishing releases

Ghosttal tracks [Ghostty](https://github.com/ghostty-org/ghostty) manually.
Upstream code reaches Ghosttal users only after it is merged, reviewed against
the fork's patch set, tested, and released through Ghosttal's own Sparkle feed.

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
zig build test
zig build -Demit-macos-app=false
./macos/build.nu --scheme Ghostty --configuration Debug --action test
```

Also launch a Debug app and manually exercise cursor/input motion, Reduce
Motion, the Ghostty-base/Ghosttal-overlay precedence, links, and update checks.

## Automated release

The preferred path is `.github/workflows/release-ghosttal.yml`. It verifies the
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

Install Zig 0.16.0, Nushell 0.115.1, Xcode 26, Sparkle 2.9.0 tools, and
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
