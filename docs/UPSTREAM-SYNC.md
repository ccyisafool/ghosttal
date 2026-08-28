# Syncing Ghosttal with upstream Ghostty and cutting a release

Ghosttal tracks upstream Ghostty **manually**: when Ghostty ships a release,
the maintainer merges it here, test-runs locally, and only then publishes a
Ghosttal release. Installed apps then receive that release through
Ghosttal's own Sparkle channel — never through Ghostty's update feed.

## Remotes

- `origin` — https://github.com/ccyisafool/ghosttal (the fork, push target)
- `upstream` — https://github.com/ghostty-org/ghostty (read-only)

## 1. Merge an upstream release

```sh
git fetch upstream --tags
git checkout -b sync/<upstream-version> main
git merge <upstream-tag-or-commit>
```

Expect conflicts concentrated where the fork diverges:

- **Motion features (the point of the fork):** `src/renderer/generic.zig`,
  `src/renderer/cursor_motion.zig`, `src/renderer/input_motion.zig`,
  `src/renderer/cell.zig`, `src/renderer/Thread.zig`,
  `src/renderer/shaders/shaders.metal`, `src/renderer/shaders/glsl/`,
  `src/renderer/{metal,opengl}/shaders.zig`, `src/config/Config.zig`,
  `src/Surface.zig`
- **Config overlay loading:** `src/config/file_load.zig`
- **Branding/identity (Ghosttal name, bundle id, icon):** `README.md`,
  `macos/Ghostty.xcodeproj/project.pbxproj`, `macos/Ghostty-Info.plist`,
  `macos/Sources/App/MainMenu.xib`, assorted user-facing Swift strings,
  `images/`
- **Update channel (keep ours, never upstream's):**
  `macos/Sources/Features/Update/UpdateDelegate.swift` (feed URL),
  `macos/Ghostty-Info.plist` (`SUPublicEDKey`, `SUEnableAutomaticChecks`)

Rule of thumb for conflicts: renderer/config conflicts need real merging
(upstream logic + Ghosttal's motion hooks); branding and update-channel
conflicts almost always resolve to the Ghosttal side with upstream's
structural changes applied around them.

After merging:

```sh
zig build test
zig build            # full app build
```

Test-run the app manually (animations, config overlay, menu items), then
merge the sync branch into `main`.

## 2. Cut a Ghosttal release (CI — the default)

GitHub Actions releases from any machine, with no local signing setup:

1. Bump versions and changelog exactly as in the manual flow below
   (`project.pbxproj`, `scripts/release-macos.sh` default, `CHANGELOG.md`),
   commit, and push `main`.
2. `git tag vX.Y.Z && git push origin vX.Y.Z`

That's all: `.github/workflows/release-ghosttal.yml` builds, signs,
notarizes, publishes the GitHub release, and pushes the regenerated
`appcast.xml` to `main` (pull after it finishes). It needs the six
repository secrets uploaded once by `scripts/setup-release-secrets.sh`,
run on a Mac that already has the certificate and Sparkle key.

## 2b. Cut a Ghosttal release (manually, on a configured Mac)

1. Bump versions — all in lockstep, or the release script refuses to run:
   - `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
     `macos/Ghostty.xcodeproj/project.pbxproj` (app target blocks).
     `CURRENT_PROJECT_VERSION` (CFBundleVersion) is what Sparkle compares —
     it must increase every release.
   - `RELEASE_VERSION` default in `scripts/release-macos.sh`.
   - Add a `CHANGELOG.md` entry.
2. Build, sign, notarize, and regenerate the appcast:

   ```sh
   ./scripts/release-macos.sh
   ```

   The script finds the notary profile (`ghosttal-notary` or `notarytool`,
   or set `NOTARY_PROFILE=`), signs the DMG with the Sparkle EdDSA key from
   the login keychain, and rewrites `appcast.xml` at the repo root.
3. Publish, in this order (so the appcast never points at a missing file):
   1. Commit the version bumps + changelog + `appcast.xml`; do **not** push yet.
   2. `git tag v<version> && git push origin v<version>`
   3. `gh release create v<version> dist/Ghosttal-<version>-universal.dmg
      --title "Ghosttal <version>"`
   4. `git push origin main` — pushing `appcast.xml` on `main` is what makes
      installed apps see the update.

## The update channel, in one paragraph

Installed apps poll
`https://raw.githubusercontent.com/ccyisafool/ghosttal/main/appcast.xml`
(hardcoded in `UpdateDelegate.feedURLString`). The appcast points at the DMG
attached to the matching GitHub release and carries an EdDSA signature made
with the private key stored in the **login keychain of the release machine**
(Keychain Access item "Private key for signing Sparkle updates"). Sparkle in
the installed app verifies that signature against `SUPublicEDKey` baked into
Info.plist, plus Apple's Developer ID signature. Losing the private key means
shipped apps will reject future updates — back it up (export with
`generate_keys -x`, store somewhere safe, import on a new machine with
`generate_keys -i`). Never commit it to the repository.
