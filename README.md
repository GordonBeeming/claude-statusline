# claude-statusline

An enhanced status line for [Claude Code](https://claude.com/claude-code) that adds repo name, git branch info, session time tracking, and token usage to the cost/context display.

## Features

- Shows current repo name with a folder icon
- GitButler support: displays active GitButler branches when on `gitbutler/workspace`
- Falls back to regular git branch display when not using GitButler
- Wraps [goccc](https://github.com/backstabslash/goccc) for cost tracking (session + daily cost in your currency)
- Rate limit progress bar (5-hour window with time remaining, color-coded green/yellow/red)
- Falls back to session duration display when rate limit data isn't available
- Token usage display (context % with input/output token counts)
- Sets terminal tab title to repo name
- Auto-updates from `main` once per day

## Status Line Example

```
📂 xylem · 🌿 gb-branch-5 · 💸 A$1.21 session · 💰 A$48.00 today · 💭 11% ctx · 🔌 2 MCPs · 🤖 Opus 4.6 · ⏱️ ██░░░░░░░░ 23% 4h0m left · 🧠 11% (45k in/12k out)
```

| Icon | Meaning |
|------|---------|
| 📂 | Repository name |
| 🌿 | GitButler active branch(es) |
| 🔀 | Regular git branch |
| 💸 | Session cost |
| 💰 | Daily cost |
| ⏱️ | 5-hour rate limit (progress bar + time remaining) |
| 🧠 | Token usage (context % + input/output counts) |

## Install

```bash
curl -sSL https://raw.githubusercontent.com/gordonbeeming/claude-statusline/main/install.sh | bash
```

This will:
1. Install/upgrade [goccc](https://github.com/backstabslash/goccc) via Homebrew
2. Copy `statusline.sh` to `~/.claude/scripts/`
3. Print instructions for updating your `~/.claude/settings.json`

After running the installer, add this to your `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/scripts/statusline.sh"
}
```

## Dependencies

- [goccc](https://github.com/backstabslash/goccc) — CLI cost calculator for Claude Code
- [jq](https://jqlang.github.io/jq/) — for parsing JSON input and GitButler output
- [GitButler CLI](https://docs.gitbutler.com/cli-overview) (`but`) — optional, for GitButler branch display

## Auto-Updates

The installed script checks once per day for updates from the `main` branch of this repo. The check runs in the background so it never slows down the status line.
