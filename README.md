# Isle

Personal Dynamic Island for the MacBook notch + a Now Playing lock screen. Spotify only.

## Build & run

```bash
xcodegen generate
xcodebuild -project Isle.xcodeproj -scheme Isle -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Isle.app
```

Menu bar icon (capsule) → settings and **Превью lock screen** (⌘L in the menu; Esc closes).

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
4. Per-app volume, coding agents, background removal, cleaner, MCP
