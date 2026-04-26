# claude-statusline

An enhanced multi-line status line for [Claude Code](https://claude.com/claude-code) that adds repo name, git branch info, model + effort level, cost tracking, rate limits, and token usage — grouped by category across four lines.

## Features

- Shows current repo name with a folder icon
- GitButler support: displays active GitButler branches when on `gitbutler/workspace`
- Falls back to regular git branch display when not using GitButler
- Shows current model name with its effort level (color-coded) and a thinking-mode indicator when extended thinking is on
- Cost tracking via [goccc](https://github.com/backstabslash/goccc) (session + daily cost in your local currency)
- Rate limit progress bar (5-hour window with time remaining, color-coded green/yellow/red)
- Falls back to session duration display when rate limit data isn't available
- Context window progress bar and token usage display
- Sets terminal tab title to repo name
- Auto-updates from `main` once per day

## Status Line Example

```
📂 xylem · 🌿 gb-branch-5
🤖 Opus 4.7 · ⚡ high · 🤔
💸 A$1.21 session · 💰 A$48.00 today · ⏱️ ██░░░░░░░░ 23% 4h0m left
💭 █░░░░░░░░░ 11% ctx · 🧠 45k in / 12k out
```

Each line groups related information:

| Line | Purpose | Contents |
|------|---------|----------|
| 1 | **Identity** | 📂 Repo name · 🌿/🔀 Branch |
| 2 | **Model** | 🤖 Model name · ⚡ Effort level · 🤔 Thinking flag |
| 3 | **Spend & limits** | 💸 Session cost · 💰 Daily cost · ⏱️ Rate limit bar |
| 4 | **Technical** | 💭 Context usage bar · 🧠 Token counts |

### Icons

| Icon | Meaning |
|------|---------|
| 📂 | Repository name |
| 🌿 | GitButler active branch(es) |
| 🔀 | Regular git branch (when not using GitButler) |
| 🤖 | Current model |
| ⚡ | Effort level (`low` dim, `medium` plain, `high` yellow, `xhigh`/`max` red) |
| 🤔 | Extended thinking is enabled (hidden when off) |
| 💸 | Session cost (local currency) |
| 💰 | Daily cost (local currency) |
| ⏱️ | 5-hour rate limit (progress bar + time remaining) |
| 💭 | Context window usage (progress bar) |
| 🧠 | Token counts (input / output) |

Progress bars are color-coded: green (<70%), yellow (70-89%), red (90%+).

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

- [goccc](https://github.com/backstabslash/goccc) — CLI cost calculator for Claude Code (session + daily costs with currency conversion)
- [jq](https://jqlang.github.io/jq/) — for parsing JSON input and GitButler output
- [GitButler CLI](https://docs.gitbutler.com/cli-overview) (`but`) — optional, for GitButler branch display

## Auto-Updates

The installed script checks once per day for updates from the `main` branch of this repo. The check runs in the background so it never slows down the status line.
