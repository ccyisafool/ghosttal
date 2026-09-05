# Changelog

## 0.1.5

- Make cursor and input animation scheduling visibility- and focus-aware so
  hidden or inactive surfaces stop requesting animation frames and resume
  cleanly when shown again.
- Track macOS Reduce Motion changes through a lock-free renderer cache instead
  of calling AppKit from frame-critical render paths.
- Make Ghostty-base and Ghosttal-overlay configuration precedence deterministic
  and add complete layer-order regression coverage.
- Strengthen release validation for versions, universal app and Dock Tile
  Plugin architectures, Swift linting, and credential-free release preflight.
- Preserve an explicitly selected Xcode toolchain throughout nested macOS build
  and test commands.

## 0.1.4

- Sync with the latest upstream Ghostty improvements while preserving
  Ghosttal's cursor and input animations under the new animation scheduler.
- Fix shell integration and Xcode launch paths so they invoke the Ghosttal
  executable correctly.
- Correct in-app help, update, release-note, commit, comparison, and source
  links to use the Ghosttal repository.
- Keep Ghosttal crash reports, SSH cache, and writable application state
  separate from stock Ghostty.
- Add a polished drag-to-Applications installer background.
- Harden signing, notarization, checksums, release retries, protected tags,
  and Sparkle appcast publishing.
- Add regression coverage for configuration-overlay precedence and prompt
  input-protocol cleanup.

## 0.1.3

- Reset stale input protocols (mouse reporting, focus reporting, and the
  Kitty keyboard protocol) whenever a new shell prompt is shown, so a
  dropped SSH session or crashed TUI no longer litters the prompt with
  unparsed mouse and key reports. Controlled by the new
  `prompt-input-protocol-reset` option (default on); requires shell
  integration prompt markers.
- Allow local development builds at Ghosttal release tags. The build
  previously refused to run when the git tag did not match upstream
  Ghostty's core version.

## 0.1.2

- Enable in-app updates via Ghosttal's own Sparkle channel. "Check for
  Updates…" and automatic checks now poll the appcast served from this
  repository and never contact Ghostty's update feed.
- Sign update downloads with a Ghosttal EdDSA key in addition to Developer
  ID code signing and notarization.
- Generate and sign the appcast as part of the scripted release flow.

## 0.1.1

- Add an Applications shortcut to the macOS installer DMG.

## 0.1.0

- Add GPU-rendered cursor motion modes: ease, spring, smear, and squash.
- Add locally echoed input-glyph motion with configurable duration and intensity.
- Respect the operating system's Reduce Motion preference by default.
- Load stock Ghostty configuration first, then apply an optional Ghosttal overlay.
- Give the macOS app an independent Ghosttal bundle identity and cat icon.
- Disable the inherited Ghostty Sparkle feed until Ghosttal has its own update channel.
- Add a scripted universal macOS build, Developer ID signing, notarization, and DMG flow.
