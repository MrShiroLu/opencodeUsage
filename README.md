# OpenCode Meter

A tiny macOS menu bar app that shows your [OpenCode](https://opencode.ai) usage at a glance.

It reads `opencode stats --json` from your machine — no account, no API key, no telemetry, no network calls.

<p align="center">
  <img src="docs/preview.png" width="330" alt="OpenCode Meter dashboard">
  <img src="docs/welcome.png" width="330" alt="OpenCode Meter welcome screen">
</p>

## Features

- **Menu bar**: today's cost, or token count when everything is free
- **Dashboard**: cost, input/output/reasoning token bars, cache tokens
- **Models**: top three models by token share
- **Activity**: 14-day bar chart, zero-filled, with weekday labels
- **Counters**: sessions, steps, prompts, tool calls
- **Periods**: Today / 7 days / 30 days / All time
- **Welcome screen**: first-run setup check (OpenCode installed? data available?)
- Light and dark mode, system accent color, no Dock icon

## Requirements

- macOS 14 or later
- [OpenCode](https://opencode.ai) installed and used at least once
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```sh
git clone https://github.com/MrShiroLu/opencodeUsage.git
cd opencodeUsage
./run.sh
```

`run.sh` builds the app, asks where to install it (default `~/Applications`), offers a
start-at-login item and launches it. On a fresh machine the welcome screen greets you
automatically. Pass `--fresh` to reset onboarding and see it again, `--yes` to accept
every default without prompts. Build settings live in `.env` (see `.env.example`).

Or build and run straight from the repo:

```sh
make run
```

## Usage

Click the menu bar item to open the dashboard.

| Control | What it does |
| --- | --- |
| `A` / `$` / `#` pill | Cycles what the menu bar shows: Automatic → Cost → Tokens |
| `?` | Reopens the welcome screen |
| ↻ | Refreshes immediately |
| ⏻ | Quits the app |

Data refreshes every 60 seconds and whenever the popover opens.

## Start at login

```sh
./Support/install-login-item.sh
```

Pass a custom app path as the first argument if you did not install to `~/Applications`.
It writes `~/Library/LaunchAgents/dev.local.opencode-meter.plist` and takes effect at the next login.

Remove it to stop launching at login:

```sh
rm ~/Library/LaunchAgents/dev.local.opencode-meter.plist
```

## How it works

The app shells out to `opencode stats --days N --cost --json`, parses the JSON and renders it with SwiftUI inside an `NSPopover`. There is no database access, no private API and no background daemon — the only moving part is the OpenCode CLI you already have.

`opencode` is looked up in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin` and `~/.local/bin`, then through a login shell (`command -v opencode`).

## Development

```sh
make build          # compile + ad-hoc sign into build/OpenCodeMeter.app
make run            # build and launch
make print          # one stats snapshot, no UI
make render         # regenerate docs/*.png from the live design
make uninstall      # remove ~/Applications/OpenCodeMeter.app
```

Design check without screen recording permissions:

```sh
OCMETER_RENDER=/tmp/meter.png build/OpenCodeMeter.app/Contents/MacOS/OpenCodeMeter
OCMETER_DEMO=1 OCMETER_RENDER=/tmp/meter-demo.png build/OpenCodeMeter.app/Contents/MacOS/OpenCodeMeter
OCMETER_WELCOME=1 OCMETER_RENDER=/tmp/welcome.png build/OpenCodeMeter.app/Contents/MacOS/OpenCodeMeter
```

## Troubleshooting

**"opencode not found"** — the CLI is not on a known path. Install it with `brew install opencode`, or start the app from a shell that has it on `PATH`.

**No data yet** — run OpenCode once so there is something in its local database.

**Numbers look stale** — stats are read live, but the menu bar value refreshes on a 60-second timer; click ↻ to force it.

## License

MIT — see [LICENSE](LICENSE).
