# claude-statusline

Self-contained Claude Code statusline. Computes daily spend by parsing
`~/.claude/projects/*/*.jsonl` directly, no `goccc` / `ccusage` dependency.

## Pricing — keep it current

Any time you change this repo, check the pricing table in `statusline.sh`
against Anthropic's current published rates before calling the change done.
The table sits next to the daily-cost jq pipeline (search for `model_rate`).

Why bother: Anthropic re-prices models out-of-cycle. The Opus 4.5+ drop
from $15/$75 to $5/$25 caused a 3× over-report that shipped to users
because the table didn't get updated. The table is the only source of
truth in this script, so a stale rate silently inflates or deflates every
user's daily total.

Sanity check by running goccc (or any third-party calculator) for the same
day and comparing. Anything more than a few percent off means the table is
wrong. Fix the rates, don't paper over them.
