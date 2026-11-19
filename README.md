# gesturekeys

Small launchd daemon that turns trackpad / Magic Mouse gestures into keyboard shortcuts
(a BetterTouchTool replacement for the few gestures I actually use).

> **Early / build-it-yourself.** No signed download yet — you build from source and sign it
> ad hoc, no certificate needed (see Install). Tested on a built-in trackpad on macOS 26 only.

| Gesture | Default |
|---|---|
| `tiptap-left` — rest one finger, tap another to its left | ⌥⌘← previous tab |
| `tiptap-right` | ⌥⌘→ next tab |
| `three-finger-click` | ⌘W close tab |

## Configure

Mappings live in `~/.config/gesturekeys/config` and reload within ~1s — no rebuild,
no restart, and no new Accessibility permission (that belongs to the signed binary, not the config).

```sh
gesturekeys list                          # current mappings
gesturekeys set tiptap-left 'cmd+shift+['  # quote combos with [ ] ; in zsh
gesturekeys set three-finger-click none   # disable
gesturekeys gestures                      # what it can detect
gesturekeys keys                          # key / modifier names
```

Or edit the file directly:

```
tiptap-left        = cmd+alt+left
tiptap-right       = cmd+alt+right
three-finger-click = cmd+w
```

## Install

1. `./install.sh` builds `GestureKeys.app`, signs it **ad hoc** (no certificate needed), loads the launchd
   agent so it starts at login, and links the CLI to `~/.local/bin/gesturekeys`
   (`DEBUG=1 ./install.sh` for verbose logs)
2. Grant Accessibility once: System Settings → Privacy & Security → **Accessibility** → **+** → add
   `GestureKeys.app` (or drag it in) and switch it on. On macOS 27 this pane may be called
   **Device Control and Data Access**. It is *not* the general "Accessibility" item in the sidebar.
3. Check it: `tail -f ~/Library/Logs/gesturekeys.log` should show `gesturekeys running`.

- **After rebuilding:** an ad-hoc signature changes every build and macOS drops the Accessibility grant.
  Switch `GestureKeys` off and on again in that list (or remove and re-add it).
- Uninstall: `launchctl bootout gui/$(id -u)/com.linh.gesturekeys; rm ~/Library/LaunchAgents/com.linh.gesturekeys.plist ~/.local/bin/gesturekeys`

## Requirements

- macOS with Xcode command line tools (`xcode-select --install`)
- Optional: a code-signing certificate, so the Accessibility grant survives rebuilds. A free Apple ID
  "Apple Development" cert (via Xcode) or a self-signed "Code Signing" cert from Keychain Access both
  work: `CODESIGN_IDENTITY="My Cert" ./install.sh`

## Known limitations

- Key names assume a **US keyboard layout**. Arrows, function keys, space, tab, return etc. work everywhere;
  letters and punctuation may hit a different key on other layouts (e.g. `z`/`y` on German QWERTZ).
- Magic Mouse is detected by the same code but hasn't been tested.
- Uses Apple's private MultitouchSupport framework, so a macOS update can break it.
- Timing thresholds are constants at the top of `main.swift`.

## Why Accessibility?

It needs to see mouse clicks (to turn a three-finger click into a shortcut and swallow the stray
tap-to-click of a TipTap) and to send keystrokes. It never reads keystrokes or screen content.

## License

MIT
