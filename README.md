# Claude Meter

A native macOS menu bar app that shows your Claude subscription usage limits (shared by claude.ai and Claude Code) and notifies you before you hit them.

- **Current session** (5-hour window): % used, % left, time until reset
- **Weekly limit** (7-day window): % used, % left, time until reset
- Model-specific weekly limits (Opus / Sonnet) when your plan reports them
- Menu bar ring icon (outer ring = session, inner ring = weekly), with an optional `59%` label
- macOS notifications at thresholds you set (default 75% and 90%), once per threshold per window
- Configurable refresh interval, launch at login

Requires macOS 13+, a Pro or Max plan, and Claude Code signed in (`claude` → `/login`).

## Where the data comes from

I compared four possible sources before building:

| Source | What it gives | Reliability |
| --- | --- | --- |
| **`GET https://api.anthropic.com/api/oauth/usage`** (used here) | `five_hour` / `seven_day` (+ `seven_day_opus`, `seven_day_sonnet`) `utilization` % and `resets_at` | The same data Claude Code's `/usage` command and claude.ai's usage page show. Authoritative, but **undocumented**, so it may change without notice. It rate-limits aggressive polling (HTTP 429). |
| Claude Code status line JSON (`rate_limits.five_hour.used_percentage`) | Same numbers | Available only inside a running Claude Code session, and only after its first API response. Good for a status line, not for a standalone app. |
| Local transcripts (`~/.claude/projects/**/*.jsonl`, e.g. `ccusage`) | Token counts for Claude Code on this Mac | Can't produce a limit %: Anthropic doesn't publish plan limits in tokens, and usage from claude.ai, the mobile apps and other machines doesn't appear. |
| claude.ai web API with a browser `sessionKey` cookie | Same numbers | Needs you to copy a browser cookie that expires. Fragile, and it looks like scraping. |

**Chosen:** the OAuth usage endpoint, authenticated with Claude Code's own OAuth token:

- **Token:** read from the macOS Keychain item `Claude Code-credentials` (via `/usr/bin/security`). If that item doesn't exist, the app falls back to `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`). The first time, macOS asks whether `security` may read the item. Click **Always Allow**.
- **Request:** `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`.
- **Read-only:** the app **never refreshes or writes the token**. Refreshing would rotate Claude Code's refresh token and could sign Claude Code out. When the access token expires, the app shows a message. As soon as you use Claude Code again, it refreshes the token and the app picks it up automatically.
- **Polling:** every 5 minutes by default (2–30 is configurable). On a 429 the app backs off (it honours `Retry-After`, waits at least 2 minutes and at most 1 hour). The Refresh button respects the backoff.
- **Privacy:** the only network request goes to `api.anthropic.com`. The token stays in memory for the length of each request.

## Architecture

```
Sources/
  ClaudeMeterCore/          Foundation only, unit tested
    Credentials.swift       Keychain (security CLI) / file token sources
    UsageAPIClient.swift    /api/oauth/usage request + status → error mapping
    UsageModels.swift       UsageWindow / UsageSnapshot + lenient JSON decoding
    Thresholds.swift        once-per-window threshold alerts (hysteresis + reset detection)
    UsageFormatting.swift   "3h 27m", "Today at 16:00", % and colour levels
  ClaudeMeter/              SwiftUI MenuBarExtra app (LSUIElement, no Dock icon)
    ClaudeMeterApp.swift    MenuBarExtra(.window) scene
    UsageStore.swift        @MainActor poll loop, backoff, error states
    PopoverView.swift       the popover UI
    SettingsPanel.swift     in-popover settings
    MenuBarIcon.swift       ring icon drawing + label
    NotificationManager.swift  UNUserNotificationCenter
Tests/ClaudeMeterCoreTests  decoding, credentials, thresholds, formatting
```

How threshold notifications work: each threshold fires once per usage window. It re-arms when the window's `resets_at` moves (a new window starts), or when usage drops more than 5 points below the threshold. If a single poll crosses several thresholds, you get one notification for the highest. Fired state is saved, so relaunching the app doesn't repeat alerts.

## Build & run

Needs Xcode 15+ (or its command line tools):

```sh
swift test                      # core unit tests
scripts/build-app.sh            # → build/Claude Meter.app (ad-hoc signed)
open "build/Claude Meter.app"
```

Move the app to `/Applications` if you want **Launch at login**. CI (GitHub Actions, `macos-14`) runs the tests and uploads a universal `ClaudeMeter.zip` artifact on every push.

Because the app is ad-hoc signed, the first time you open a downloaded build: right-click → **Open**, or run `xattr -dr com.apple.quarantine "Claude Meter.app"`.

## Troubleshooting

- **"No Claude Code sign-in found"**: install Claude Code, run `claude`, then `/login` with your Pro/Max account.
- **"Keychain access was denied"**: press Refresh and choose **Always Allow** in the prompt.
- **"sign-in token expired"**: use Claude Code once (any prompt) and it refreshes the token.
- **"Rate limited"**: the endpoint throttles frequent callers. The app retries automatically. Consider a longer refresh interval.

## Limitations / next steps

- The endpoint is unofficial. If Anthropic changes it, parsing fails with a visible error instead of showing wrong numbers.
- API-key (Console) usage is not covered: those accounts have no subscription windows.
- Ideas: a "limit reset" notification, a usage history sparkline, a status line bridge as a second data source.

Not affiliated with or endorsed by Anthropic.
