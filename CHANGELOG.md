# Changelog

## Unreleased

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
