# Isle

Personal Dynamic Island for the MacBook notch + a Now Playing lock screen. Spotify only.

## Install

```bash
./scripts/install.sh
```

Builds Release, replaces `/Applications/Isle.app` and launches it. The installed copy starts at
login (toggle in the menu: «Запускать при входе») and is the one Claude Code hooks / MCP point to.

## Develop

```bash
xcodegen generate
xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug -derivedDataPath build build
```

Dev builds never take over the hook / MCP shims and refuse to run next to the installed copy;
check UI with `--snapshot` / `--uitest`, then `./scripts/install.sh`.

Menu bar icon (capsule) → settings, lock screen preview and editor, clipboard (⌥⇧V), converter (⌥⇧C).

First Spotify call asks for Automation permission (System Settings → Privacy & Security → Automation).

## Render snapshots (no locking needed)

```bash
build/Build/Products/Debug/Isle.app/Contents/MacOS/Isle --snapshot ./snapshots [--art cover.jpg]
```

Uses the live Spotify track if one is playing, otherwise sample data. `ISLE_FORCE_DEPTH=1` skips the
Clock Depth guard (debug).

## How it works

| Part | Where | How |
|---|---|---|
| Spotify state | `Spotify/SpotifyController.swift` | `com.spotify.client.PlaybackStateChanged` notification + AppleScript poll, position interpolated |
| Lock screen window | `LockScreen/SkyLight.swift` | private SkyLight space above the lock screen (technique from [Lakr233/SkyLightWindow](https://github.com/Lakr233/SkyLightWindow), MIT) |
| Clock Depth | `Media/ArtworkProcessor.swift` | Vision foreground mask; skipped when the subject covers >35% of the clock |
| Lyrics | `Media/LyricsService.swift` | [LRCLIB](https://lrclib.net) synced lyrics |
| Notch | `Notch/` | non-activating panel over the notch, hover via mouse monitors |

Private APIs (SkyLight) can break with macOS updates.

## Roadmap

1. ✅ Now Playing + lock screen + lyrics + notch player + password dots
2. ✅ Notch shelf: tabs, calendar (EventKit), weather (Open-Meteo, coords rounded to ~1 km), widget editor
3. ✅ Volume/brightness HUD (media-key event tap, needs Accessibility), System Stats widget, Batteries widget
4. ✅ Coding agents (Claude Code hooks → local socket), MCP server (`Isle --mcp`, per-tool opt-in),
   background removal (drop on the notch → PNG on clipboard), Cleaner (app + leftovers → Trash),
   per-app volume (CoreAudio process taps)
   + shelf pages (scroll / swipe), clipboard history (⌥⇧V), file tray, currency widget + converter (⌥⇧C),
   lock screen editor (clock font / colour, widgets row, player style, background)
5. iPhone companion: send to Mac clipboard, shared clipboard, Mac widgets, agent Live Activity

## Debug entry points

| Flag | What |
|---|---|
| `--snapshot <dir>` | render views to PNG |
| `--uitest` | click shelf editor buttons in an invisible window |
| `--probe` | Spotify AppleScript fields |
| `--remove-bg <in> <out>` | background removal pipeline |
| `--clean-scan <app>` | Cleaner dry run |
| `--install-hooks` | add Claude Code hooks |
| `--hook <source>` / `--mcp` | hook forwarder / MCP stdio server |
| `--convert <queries…>` | currency parser against live rates |
| `--mixer-selftest` (via `open --args`) | tap the playing app at 50% for 4 s, log to ~/Library/Logs/Isle/lock.log |
