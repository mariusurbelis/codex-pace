# Codex Pace

A native macOS menu bar tracker for the quota on your signed-in Codex account. It compares **quota remaining** with **time remaining** so you can spread usage across the reset window.

## Install

Download the universal ZIP from the [latest release](https://github.com/mariusurbelis/codex-pace/releases/latest), unzip it, and move **Codex Pace.app** to `/Applications` or `~/Applications`. Open the app and look for it in the **menu bar**.

Requires **macOS 14 or later**, on Apple Silicon or Intel, and a separately installed Codex CLI signed in on each Mac. The download includes the app; it does not include Codex or transfer your sign-in between computers. Xcode and Swift are only needed to build from source.

The initial release is locally (ad hoc) signed, without a Developer ID signature or Apple notarization. macOS may require explicit approval in **System Settings → Privacy & Security** after you first try to open it. Follow [Apple’s guidance for safely opening apps](https://support.apple.com/en-us/102445) if you choose to approve the downloaded app.

## At a glance

The menu bar can show the selected allowance’s remaining percentage or its pace balance. Choose **Settings → Menu bar shows → Above / below pace** for a signed value such as `+12.3 pts`: extra allowance available before reaching the even-use pace. `−3.2 pts` means a shortfall, and `0.0 pts` means on pace. These are percentage points of the full quota, not a prompt count. The choice is saved across launches.

Click it to see remaining quota, the pace difference, reset time, and the daily allowance that would last until reset. The bar is blue up to the even-use marker, green for remaining quota above pace, and gray for quota already used. When below pace, the remaining quota stays blue and the shortfall is labeled in orange.

**More details** starts collapsed and contains the exact even-use target, update timing, refresh and dashboard actions, and recent allowance changes. Old readings and update failures remain visible in the main view.

## Build from source

Requires macOS 14 or later, Xcode or Swift command-line tools, and a separately installed Codex CLI already signed in with your ChatGPT account.

```bash
git clone https://github.com/mariusurbelis/codex-pace.git
cd codex-pace
./scripts/run.sh
```

This builds `dist/Codex Pace.app`, signs it locally, and opens it. Look in the **menu bar**, not the Dock. Once built, open the app directly without rebuilding:

```bash
open "dist/Codex Pace.app"
```

The Settings menu contains **Menu bar shows**, **Launch at login**, **Choose Codex CLI…**, and **Quit Codex Pace**. Launch at login starts disabled. If you want a permanent installation, copy the app to `~/Applications` and enable the login item from that copy. Quit a running copy before replacing it with a new build.

You can also manage the installed app's login item from Terminal, without opening the popover:

```bash
"/Applications/Codex Pace.app/Contents/MacOS/CodexPace" --launch-at-login enable
"/Applications/Codex Pace.app/Contents/MacOS/CodexPace" --launch-at-login status
"/Applications/Codex Pace.app/Contents/MacOS/CodexPace" --launch-at-login disable
```

Use the path to your installed copy (for example, `~/Applications` instead). Each command prints its bundle path and login-item status. Only `enabled` confirms automatic launch; `requires-approval` needs approval in System Settings → General → Login Items, and enabling exits unsuccessfully until approved. These commands run separately from other options and do not read quota.

## Refresh and reset behavior

- Refreshes on launch, every five minutes while awake, after waking, and shortly after a reported upcoming reset. **Refresh now** is always available when no request is active.
- The menu bar redraws every minute so its pace balance follows elapsed time. This does not trigger extra quota reads. When quota is stale or pace metadata is unavailable, pace mode shows `— pts` until a fresh reading is available.
- Each refresh starts a short-lived `codex app-server` helper, reads account quota, then closes the helper. There is no persistent Codex helper and no inference turn.
- Every successful response replaces the stored usage percentage, window duration, and reset timestamp. Normal weekly resets and applied resets therefore appear on the next successful read once the service reports them.
- Restored quota and changed reset schedules appear under **Recent allowance changes**. The tracker reports the observed change; it cannot prove whether a person, scheduled reset, or service adjustment caused it.
- The local clock never restores quota. If the reported reset has passed but no fresh values arrive, the app labels the reading as old and waits for the service.
- Failed reads retain the previous values and their age. Retries back off from five minutes up to one hour, with a little jitter. Choosing **Refresh now** requests another read immediately.
- Weekly windows are identified by their actual `10080`-minute duration, in either the primary or secondary field. If several windows or buckets are returned, use the allowance picker to inspect them independently.

OpenAI does not publish a polling-specific allowance for `account/rateLimits/read`. Five-minute polling is a conservative implementation choice, not a guaranteed service rate limit. Wake and reset refreshes may add requests to the regular cadence.

## Pacing calculation

```text
remaining       = clamp(100 − usedPercent, 0, 100)
targetRemaining = clamp(100 × secondsUntilReset / windowSeconds, 0, 100)
paceGap         = remaining − targetRemaining
dailyAllowance  = remaining / daysUntilReset
```

For a seven-day window, the marker starts at 100%, reaches 50% after 3½ days, and reaches 0% at reset. After one day, 60% remaining is 25.7 percentage points below the even-use marker of 85.7%.

The daily allowance is percentage points of the whole quota per 24 hours. It is planning guidance: task cost varies, and it does not promise a number of prompts. Missing reset metadata suppresses pace calculations. Expired windows keep their last known quota without inventing a rollover.

## Sign-in and local data

Codex manages authentication and token refresh using its existing configuration. This app does not read, copy, or store authentication tokens and does not need a separate API key. Sign in through Codex or `codex login` if needed.

CLI discovery checks `CODEX_PACE_CLI`, common installation paths, `PATH`, and the bundled Codex executable in ChatGPT/Codex.app. Use **Choose Codex CLI…** if your installation is elsewhere. For a single launch:

```bash
open "dist/Codex Pace.app" --args --cli /absolute/path/to/codex
```

Only parsed quota values and recent change notices are cached in:

```text
~/Library/Application Support/CodexPace/usage.json
```

The cache has owner-only permissions. Selected allowance and CLI preferences use macOS UserDefaults under `local.codexpace.tracker`. Raw server errors and stderr are not retained. The app makes no analytics requests; the helper follows your existing Codex configuration.

The displayed meter covers the buckets the account endpoint actually returns. The app does not assume that every ChatGPT feature shares that meter.

## Development and CLI

No third-party packages or web runtime are required.

```bash
swift test
./scripts/build.sh                  # Optimized, locally signed app bundle
./scripts/build.sh debug            # Debug app bundle
./scripts/release.sh                # Universal release ZIP and SHA256SUMS
swift run CodexPace --once           # Fresh account quota as JSON, then exit
swift run CodexPace --demo --show     # Sample UI, no quota request
```

The release command builds for Apple Silicon and Intel, verifies both architectures and the local signature, and writes `dist/Codex-Pace-<version>-macos-universal.zip` with `dist/SHA256SUMS`. The version comes from `Resources/Info.plist`. It does not publish a GitHub release.

GitHub Actions runs tests and builds the universal release archive on pushes and pull requests. The ZIP and checksum are available as a workflow artifact.

The built executable also supports `--once`, so scripts can read quota without Swift installed:

```bash
"dist/Codex Pace.app/Contents/MacOS/CodexPace" --once
```

For deterministic layout inspection:

```bash
swift run CodexPace --preview /absolute/path/light.png
swift run CodexPace --preview /absolute/path/dark.png --dark
swift run CodexPace --preview /absolute/path/details.png --dark --details
swift run CodexPace --preview /absolute/path/behind.png --dark --preview-state behind
```

Preview states are `ahead` (default), `behind`, `balanced`, `missing`, `expired`, `stale`, `failure`, `empty`, `disconnected`, `multiple`, `zero`, and `full`. These use local fixtures and do not read account data. `--demo --preview-state behind --show` opens an interactive fixture for native popover checks.

Tests cover pacing, malformed/missing metadata, multiple buckets, reset changes, Codable caching, JSONL handshake/notifications, authentication errors, throttling, helper timeouts, cancellation, and process cleanup. Transport tests use local fake executables and never generate model output.

Sources are separated into `QuotaCore` (parsing and calculations), `CodexUsage` (short-lived helper), and `CodexPace` (native UI, scheduling, and local cache).

The app-server protocol can change with Codex updates; update the app if a future response shape changes.

Official protocol: [Codex app-server](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt), including [applied resets](https://learn.chatgpt.com/docs/app-server#8-earned-rate-limit-resets-chatgpt).
