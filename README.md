# claude-statusline

An enhanced multi-line status line for [Claude Code](https://claude.com/claude-code) that adds repo name, git branch info, model + effort level, cost tracking, rate limits, and token usage — grouped by category across four lines.

## Features

- Shows current repo name with a folder icon
- Git worktree aware: line 1 names the repo a worktree belongs to, and line 2 names the worktree itself
- Shows the current git branch, folded into one entry when it and the worktree folder are two spellings of the same name, with an optional prefix to leave out of the display
- Shows current model name with its effort level (color-coded) and a thinking-mode indicator when extended thinking is on
- Cost tracking with native USD→local conversion (session + daily cost), no external CLI required
- Rate limit progress bar (5-hour window with time remaining, color-coded green/yellow/red)
- Falls back to session duration display when rate limit data isn't available
- Context window progress bar and token usage display
- Subagent rows: shows each running teammate's model in the agent panel (via `subagentStatusLine`)
- Auto-updates from `main` once per day

## Status Line Example

The main session shows the four-line block:

```
📂 my-app · 🤖 Opus 4.7 (1M context) · ⚡ high · 🤔
🌳 gb/feature/dark-mode
💸 A$3.14 session · 💰 A$72.50 today · ⏱️ ████░░░░░░ 42% 2h15m left
💭 ███░░░░░░░ 31% ctx · 🧠 89k in / 14k out
```

When you have teammates running, the agent panel below the prompt adds one row per running teammate (see [Subagent rows](#subagent-rows)):

```
↳ 🐝 pr-pilot · 🔮 Sonnet 5 · ↓ 81.8k tok
↳ 🐝 explorer · 🍃 Haiku 4.5 · ↓ 12.1k tok
```

Each line of the main block groups related information:

| Line | Purpose | Contents |
|------|---------|----------|
| 1 | **Identity + Model** | 📂 Repo name · 🤖 Model (with context variant in parens, e.g. `(1M context)`, when Claude Code reports one) · ⚡ Effort · 🤔 Thinking flag |
| 2 | **Worktree + branch** | 🌳 Worktree · 🔀 Branch |
| 3 | **Spend & limits** | 💸 Session cost · 💰 Daily cost · ⏱️ Rate limit bar |
| 4 | **Technical** | 💭 Context usage bar · 🧠 Token counts |

Line 2 changes shape with where you are:

| Worktree folder | Branch | What you see |
|-----------------|--------|--------------|
| (main checkout) | `main` | `🔀 main` |
| `dark-mode` | `gb/feature/dark-mode` | `🌳 gb/feature/dark-mode` |
| `gb+fix+9109-shuffle` | `gb/fix/9109-shuffle` | `🌳 gb/fix/9109-shuffle` |
| `legacy-name` | `worktree-legacy-name` | `🌳 worktree-legacy-name` |
| `dark-mode` | `gb/chore/theme-tokens` | `🌳 dark-mode · 🔀 gb/chore/theme-tokens` |
| `dark-mode` | (detached HEAD) | `🌳 dark-mode` |
| (not a git repo) | | line 2 is omitted |

When the folder and the branch are two spellings of the same name, you only get one of them, and it's the branch: that's the name someone chose for the work, where the folder is whatever the tool creating the worktree could spell. The 🌳 already tells you it's a worktree, and line 1 keeps naming the repo, which is what tells several open worktrees apart.

The comparison is separator-blind, so it holds up when a branch and its folder disagree about punctuation. `/` and `+` both count as separators, case is ignored, and a leading `worktree-` is discounted. That last one matters if you drive worktrees from a launcher: `claude -w` can't put a slash in a branch name, so asking it for `gb/fix/x` gets you the folder `gb+fix+x` and the branch `worktree-gb+fix+x`, and those still read as one name. A branch left as `worktree-…` is shown with the prefix intact so you can see the rename hasn't happened yet.

This line gets the full terminal width and never wraps. If both halves are present and won't fit, the branch is truncated with `…` first, and dropped entirely when fewer than 8 characters would survive.

### Icons

| Icon | Meaning |
|------|---------|
| 📂 | Repository name |
| 🌳 | Git worktree (shown instead of 🔀 when the branch name matches the worktree) |
| 🔀 | Current git branch |
| 🤖 | Current model |
| ⚡ | Effort level (`low` dim, `medium` plain, `high` yellow, `xhigh`/`max` red) |
| 🤔 | Extended thinking is enabled (hidden when off) |
| 💸 | Session cost (local currency) |
| 💰 | Daily cost (local currency) |
| ⏱️ | 5-hour rate limit (progress bar + time remaining) |
| 💭 | Context window usage (progress bar) |
| 🧠 | Token counts (input / output) |

Progress bars are color-coded: green (<70%), yellow (70-89%), red (90%+).

## Subagent rows

When you run background teammates or subagents, Claude Code draws one row per teammate in the agent panel below the prompt. The default row is `name · description · token count`, which never tells you which model a teammate is on: a Sonnet teammate looks identical to an Opus one. This project ships a second script, `subagent-statusline.sh`, that rewrites those rows to put the model front and centre (see the [example above](#status-line-example)):

- `↳ 🐝` marks a spawned worker nested under the main session.
- The model glyph and name come from the teammate's own transcript, since the panel data doesn't include the model. It fills in as soon as the teammate's first response lands; before that, the row shows without a model.
- Only **actively-running** teammates appear. Finished and idle rows are hidden, so the panel goes quiet once the work is done.

### Model glyphs

| Glyph | Model family |
|-------|--------------|
| 🦉 | Opus |
| 🔮 | Sonnet |
| 🍃 | Haiku |
| 📖 | Fable / Mythos |

A model outside these families keeps its row but drops the glyph and name.

To enable it, add `subagentStatusLine` alongside `statusLine` in `~/.claude/settings.json`:

```json
"subagentStatusLine": {
  "type": "command",
  "command": "~/.claude/scripts/subagent-statusline.sh"
}
```

## Install

```bash
curl -sSL https://raw.githubusercontent.com/gordonbeeming/claude-statusline/main/install.sh | bash
```

This will:
1. Copy `statusline.sh` and `subagent-statusline.sh` to `~/.claude/scripts/`
2. Print instructions for updating your `~/.claude/settings.json`

After running the installer, add this to your `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/scripts/statusline.sh"
},
"subagentStatusLine": {
  "type": "command",
  "command": "~/.claude/scripts/subagent-statusline.sh"
}
```

The `subagentStatusLine` line is optional — leave it out if you only want the main status line.

## Dependencies

- [jq](https://jqlang.github.io/jq/) — for parsing the JSON input and the transcript cost calculation

## Currency

Set `STATUSLINE_CURRENCY` (default `AUD`) to choose the display currency. Set it to `USD` for zero-network behaviour. Other supported codes with a custom symbol: `GBP`, `EUR`, `NZD`, `CAD`, `JPY`. Any ISO 4217 code with a rate on [open.er-api.com](https://open.er-api.com) also works; unknown codes render with the code as a prefix (e.g. `CHF 12.34`). Anything that doesn't match the ISO shape (three uppercase letters) silently falls back to AUD.

The USD→local rate is fetched once per day and cached at `~/.claude/scripts/.fx-cache-<CCY>`. If the fetch fails and no cached rate is available, the statusline falls back to USD silently.

## Hiding a branch prefix

If every branch you make starts the same way, that prefix costs you characters on line 2 without telling you anything. Set `STATUSLINE_IGNORE_PREFIXES` to drop it from the displayed name:

```sh
export STATUSLINE_IGNORE_PREFIXES="gb/*/"
```

Entries are comma-separated, and each one is a shell glob anchored at the start of the name, so a `gb/<category>/<slug>` convention needs one `gb/*/` rather than a row per category. With that set, a worktree on `gb/fix/9109-shuffle` shows as `🌳 9109-shuffle`.

The setting is empty by default and only affects the folded single-name form. When the folder and branch disagree and both halves print, the branch keeps its prefix, because that's the case where the prefix is the surprising part. A pattern that would swallow an entire name is ignored rather than leaving you with a blank line.

## Cost calculation

Daily cost is computed by scanning `~/.claude/projects/*/*.jsonl` for today's usage records and pricing them against an inline table covering the Fable / Mythos, Opus, Sonnet and Haiku families (source: [Anthropic's pricing page](https://platform.claude.com/docs/en/about-claude/pricing)). The result is cached for 60 seconds. A model with no row in the table is skipped rather than priced at zero, so if a new release makes your total look low, add its rates to the table in `statusline.sh` (search for `model_rate`).

## Auto-Updates

The installed script checks once per day for updates from the `main` branch of this repo and refreshes both `statusline.sh` and `subagent-statusline.sh`. The check runs in the background so it never slows down the status line.
