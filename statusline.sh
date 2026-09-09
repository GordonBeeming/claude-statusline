#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.claude/scripts"
INSTALLED_SCRIPT="${INSTALL_DIR}/statusline.sh"
UPDATE_MARKER="${INSTALL_DIR}/.statusline-last-update"
REPO_URL="https://raw.githubusercontent.com/gordonbeeming/claude-statusline/main/statusline.sh"
# The subagent statusline ships from the same repo and rides this script's
# once-a-day update so it never goes stale after install, without paying its own
# network cost (it runs on every agent-panel tick and must stay fast).
SUBAGENT_INSTALLED="${INSTALL_DIR}/subagent-statusline.sh"
SUBAGENT_REPO_URL="https://raw.githubusercontent.com/gordonbeeming/claude-statusline/main/subagent-statusline.sh"

# ANSI colors
RED='\033[31m'
YELLOW='\033[33m'
GREEN='\033[32m'
DIM='\033[2m'
RESET='\033[0m'

# --- Auto-update (once per day) ---
auto_update() {
  local now
  now=$(date +%s)
  local last_update=0
  if [[ -f "$UPDATE_MARKER" ]]; then
    last_update=$(cat "$UPDATE_MARKER" 2>/dev/null || echo 0)
  fi
  local age=$(( now - last_update ))
  if (( age >= 86400 )); then
    (
      # Refresh both scripts from main. Each is validated (non-empty + shebang)
      # before it replaces the installed copy, so a truncated download can't
      # clobber a working script.
      for pair in "${REPO_URL}::${INSTALLED_SCRIPT}" "${SUBAGENT_REPO_URL}::${SUBAGENT_INSTALLED}"; do
        url="${pair%%::*}"
        dest="${pair##*::}"
        tmp=$(mktemp)
        if curl -sSL --max-time 5 "$url" -o "$tmp" 2>/dev/null; then
          if [[ -s "$tmp" ]] && head -1 "$tmp" | grep -q '^#!/'; then
            cp "$tmp" "$dest"
            chmod +x "$dest"
          fi
        fi
        rm -f "$tmp"
      done
      echo "$now" > "$UPDATE_MARKER"
    ) &>/dev/null &
    disown 2>/dev/null || true
  fi
}

auto_update

# --- Read stdin (session JSON) ---
stdin_data=$(cat)

# --- Extract all fields from JSON in one jq call ---
eval "$(echo "$stdin_data" | jq -r '
  @sh "cwd=\(.workspace.current_dir // .cwd // "")",
  @sh "model_name=\(.model.display_name // "")",
  @sh "model_id=\(.model.id // "")",
  @sh "session_cost_usd=\(.cost.total_cost_usd // 0)",
  @sh "duration_ms=\(.cost.total_duration_ms // 0)",
  @sh "ctx_pct=\(.context_window.used_percentage // 0)",
  @sh "ctx_size=\(.context_window.context_window_size // 0)",
  @sh "total_input=\(.context_window.total_input_tokens // 0)",
  @sh "total_output=\(.context_window.total_output_tokens // 0)",
  @sh "five_hour_pct=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "five_hour_resets=\(.rate_limits.five_hour.resets_at // "")",
  @sh "effort_level=\(.effort.level // "")",
  @sh "thinking_enabled=\(.thinking.enabled // false)"
' 2>/dev/null || echo 'cwd=""; model_name=""; model_id=""; session_cost_usd=0; duration_ms=0; ctx_pct=0; ctx_size=0; total_input=0; total_output=0; five_hour_pct=""; five_hour_resets=""; effort_level=""; thinking_enabled=false')"

# --- Currency, FX rate, and daily cost (self-contained — no external CLI) ---
# Currency picked via STATUSLINE_CURRENCY (default AUD). USD short-circuits the
# network entirely so $-only users incur zero overhead.
currency_code="${STATUSLINE_CURRENCY:-AUD}"
currency_code=$(printf '%s' "$currency_code" | tr '[:lower:]' '[:upper:]')
# Validate — the code interpolates into a cache file path, so anything off the
# ISO 4217 shape (3 uppercase letters) gets rejected to keep a value like
# `../foo` from escaping the cache dir.
[[ "$currency_code" =~ ^[A-Z]{3}$ ]] || currency_code="AUD"

case "$currency_code" in
  USD) currency_symbol='$'   ;;
  AUD) currency_symbol='A$'  ;;
  GBP) currency_symbol='£'   ;;
  EUR) currency_symbol='€'   ;;
  NZD) currency_symbol='NZ$' ;;
  CAD) currency_symbol='C$'  ;;
  JPY) currency_symbol='¥'   ;;
  *)   currency_symbol="${currency_code} " ;;
esac

currency_rate=1

# FX cache: ${INSTALL_DIR}/.fx-cache-<CCY> — first line is the rate, second
# line is the unix epoch when it was fetched. Refreshed at most every 24h; on
# fetch failure we keep using the stale value rather than spam the source.
fx_cache_file="${INSTALL_DIR}/.fx-cache-${currency_code}"
if [[ "$currency_code" != "USD" ]]; then
  fx_now=$(date +%s)
  fx_rate=""
  fx_ts=0
  if [[ -f "$fx_cache_file" ]]; then
    fx_rate=$(sed -n '1p' "$fx_cache_file" 2>/dev/null || echo "")
    fx_ts=$(sed -n '2p' "$fx_cache_file" 2>/dev/null || echo 0)
  fi
  # A corrupted/partial cache must not crash the render under `set -e`. The
  # rate is validated against a decimal-number shape; the timestamp against
  # an integer shape. Anything else is treated as cache-miss.
  [[ "$fx_rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fx_rate=""
  [[ "$fx_ts" =~ ^[0-9]+$ ]] || fx_ts=0
  fx_age=$(( fx_now - fx_ts ))
  if [[ -z "$fx_rate" || "$fx_age" -ge 86400 ]]; then
    fetched=$(curl -sSL --connect-timeout 2 --max-time 3 \
      "https://open.er-api.com/v6/latest/USD" 2>/dev/null \
      | jq -r --arg c "$currency_code" '.rates[$c] // empty' 2>/dev/null || true)
    if [[ -n "$fetched" && "$fetched" != "null" ]]; then
      mkdir -p "$INSTALL_DIR" 2>/dev/null || true
      printf '%s\n%s\n' "$fetched" "$fx_now" > "$fx_cache_file" 2>/dev/null || true
      fx_rate="$fetched"
    fi
  fi
  if [[ -n "$fx_rate" && "$fx_rate" != "null" ]]; then
    currency_rate="$fx_rate"
  else
    # No rate available (no cache + no network) — degrade to USD silently.
    currency_symbol='$'
  fi
fi

# Daily cost: today's USD spend across every project, derived from
# ~/.claude/projects/*/*.jsonl. Cached for 60s so the statusline isn't
# repeatedly scanning the transcript tree at typing speed. Cache busts on
# local date rollover.
daily_cost_usd=0
daily_cache_file="${INSTALL_DIR}/.daily-cost-cache"
today_local=$(date '+%Y-%m-%d')
need_recompute=true
if [[ -f "$daily_cache_file" ]]; then
  c_total=$(sed -n '1p' "$daily_cache_file" 2>/dev/null || echo "")
  c_ts=$(sed -n '2p' "$daily_cache_file" 2>/dev/null || echo 0)
  c_day=$(sed -n '3p' "$daily_cache_file" 2>/dev/null || echo "")
  # Treat any corrupt/non-numeric cache line as a miss — the script runs
  # under `set -e` so an arithmetic error here would abort the whole render.
  [[ "$c_ts" =~ ^[0-9]+$ ]] || c_ts=0
  [[ "$c_total" =~ ^[0-9]+(\.[0-9]+)?$ ]] || c_total=""
  # Carry today's last known total forward as a fallback so a transient
  # recompute failure (jq parse error, date parse failure) doesn't blank
  # out the daily display — the next successful recompute will refresh it.
  if [[ -n "$c_total" && "$c_day" == "$today_local" ]]; then
    daily_cost_usd="$c_total"
    if (( $(date +%s) - c_ts < 60 )); then
      need_recompute=false
    fi
  fi
fi
if [[ "$need_recompute" == "true" ]]; then
  # Local-day window expressed as UTC epoch bounds. BSD `date -j -f` (macOS)
  # and GNU `date -d` use incompatible syntax for parsing a date string —
  # try both so the script keeps working if anyone runs it on Linux. If
  # neither succeeds we skip the recompute entirely rather than silently
  # treating "epoch 0" as today (which would zero out the daily total).
  day_lo=$(date -j -f '%Y-%m-%d %H:%M:%S' "${today_local} 00:00:00" '+%s' 2>/dev/null \
    || date -d "${today_local} 00:00:00" '+%s' 2>/dev/null \
    || echo "")
  # recompute_ok stays false on any failure path (date parse failure, jq
  # parse error on a half-written .jsonl). Only a successful recompute
  # writes the cache — otherwise we'd clobber the last good value with 0
  # and silently suppress the daily display for the full 60s TTL.
  recompute_ok=false
  if [[ -n "$day_lo" ]]; then
    day_hi=$(( day_lo + 86400 ))
    projects_dir="${HOME}/.claude/projects"
    jsonl_files=()
    if [[ -d "$projects_dir" ]]; then
      # 26h window of mtimes catches anything that could still be writing
      # records inside today's local-time window.
      while IFS= read -r f; do
        [[ -n "$f" ]] && jsonl_files+=("$f")
      done < <(find "$projects_dir" -type f -name '*.jsonl' -mmin -1560 2>/dev/null)
    fi
    if (( ${#jsonl_files[@]} > 0 )); then
      # Pricing table — USD per 1M tokens. Source:
      # https://platform.claude.com/docs/en/about-claude/pricing
      # Fable / Mythos ($10/$50) are the top tier, above Opus. Mythos (Project
      # Glasswing limited availability) shares Fable's rate at every point
      # version, so each branch covers both. Their ids have no `opus`
      # substring, so ordering vs. the opus branches doesn't matter for
      # correctness — they sit first so the priciest tier is easy to spot.
      # The .1 models break the usual 0.1x cache-read multiplier: their cache
      # hits are 0.025x base input ($0.25), so they need their own branch
      # ahead of the generic `fable|mythos` fallback. Cache reads dominate a
      # Claude Code day, so folding them into the $1.00 row over-reports a
      # heavy Fable 5.1 day by more than 2x.
      # Opus 4.5+ is priced 1/3 of older Opus (4.1, 3) — Anthropic dropped the
      # rate for the newer models. The newer branch must be matched *before* the
      # generic `opus` fallback so it wins for `claude-opus-4-7-…` etc. Sonnet 5+
      # gets its own branch before the generic `sonnet` fallback because its
      # $2/$10 launch rate — originally announced as introductory pricing
      # through 2026-08-31 — was made permanent, while Sonnet 4.6 and earlier
      # stay $3/$15. Haiku
      # 4.x is its own bucket ($1/$5 with 1h cache write $2 — note 2x not 2.5x).
      # Haiku 3.5 is matched before legacy Haiku 3 so `claude-3-5-haiku-…`
      # doesn't fall into the cheaper bucket. Any model with no row here returns
      # null and is dropped by the `select(model_rate(...) != null)` filter — so
      # an unpriced model silently *under-counts* the daily total (excluded, not
      # zero-weighted). Keep this table current when Anthropic ships or re-prices
      # a model, or that model's spend vanishes from the daily figure.
      # Dedupe by message.id|requestId — Claude Code transcripts re-emit the
      # same usage record multiple times (streaming progress events, session
      # resume rewrites). Without dedup the same tokens get billed N times,
      # inflating the daily total by 2–5x vs. tools like ccusage/goccc.
      # Records missing both IDs are passed through un-deduped so they aren't
      # collapsed into a single bucket (which would under-count).
      #
      # The `|| jq_exit=$?` is load-bearing: under `set -e` a non-zero exit
      # from the command substitution would otherwise abort the script before
      # we get a chance to handle the failure. With the `|| ...` guard the
      # exit code is captured and the next block falls back to the cached
      # value instead of crashing the render.
      jq_exit=0
      jq_raw=$(jq -n -r --argjson lo "$day_lo" --argjson hi "$day_hi" '
        def model_rate($m):
          ($m | ascii_downcase) as $lm
          | if   ($lm | test("fable-5-1|mythos-5-1"))      then {i:10,   o:50,   cw5:12.50,  cw1h:20,    cr:0.25}
            elif ($lm | test("fable|mythos"))              then {i:10,   o:50,   cw5:12.50,  cw1h:20,    cr:1.00}
            elif ($lm | test("opus-4-[5-9]|opus-[5-9]"))   then {i:5,    o:25,   cw5:6.25,   cw1h:10,    cr:0.50}
            elif ($lm | test("opus"))                      then {i:15,   o:75,   cw5:18.75,  cw1h:30,    cr:1.50}
            elif ($lm | test("sonnet-5|sonnet-[6-9]"))     then {i:2,    o:10,   cw5:2.50,   cw1h:4,     cr:0.20}
            elif ($lm | test("sonnet"))                    then {i:3,    o:15,   cw5:3.75,   cw1h:6,     cr:0.30}
            elif ($lm | test("haiku-4|haiku-[5-9]"))       then {i:1,    o:5,    cw5:1.25,   cw1h:2,     cr:0.10}
            elif ($lm | test("3-5-haiku|haiku-3-5"))       then {i:0.80, o:4,    cw5:1,      cw1h:1.60,  cr:0.08}
            elif ($lm | test("3-haiku|haiku-3"))           then {i:0.25, o:1.25, cw5:0.3125, cw1h:0.50,  cr:0.025}
            elif ($lm | test("haiku"))                     then {i:1,    o:5,    cw5:1.25,   cw1h:2,     cr:0.10}
            else null end;
        [ inputs
          | select(.timestamp != null and (.message.usage // null) != null and (.message.model // null) != null)
          | (((.timestamp[0:19] + "Z") | fromdateiso8601?) // 0) as $ts
          | select($ts >= $lo and $ts < $hi)
          | select(model_rate(.message.model) != null)
        ]
        | (map(select((.message.id // "") != "" or (.requestId // "") != ""))
            | unique_by((.message.id // "") + "|" + (.requestId // "")))
          + map(select((.message.id // "") == "" and (.requestId // "") == ""))
        | .[]
        | model_rate(.message.model) as $r
        | .message.usage as $u
        | ((($u.input_tokens // 0)              * $r.i)
          + (($u.output_tokens // 0)            * $r.o)
          + (($u.cache_read_input_tokens // 0)  * $r.cr)
          + (if ($u.cache_creation // null) != null
               then (($u.cache_creation.ephemeral_5m_input_tokens // 0) * $r.cw5)
                  + (($u.cache_creation.ephemeral_1h_input_tokens // 0) * $r.cw1h)
               else (($u.cache_creation_input_tokens // 0) * $r.cw5)
             end)) / 1000000
      ' "${jsonl_files[@]}" 2>/dev/null) || jq_exit=$?
      if [[ "$jq_exit" -eq 0 ]]; then
        daily_cost_usd=$(printf '%s\n' "$jq_raw" | awk 'BEGIN{s=0} {s+=$1} END{printf "%.4f", s+0}')
        recompute_ok=true
      fi
    else
      # No transcript files to scan — legitimate zero, safe to cache.
      daily_cost_usd=0
      recompute_ok=true
    fi
  fi
  if [[ "$recompute_ok" == "true" ]]; then
    mkdir -p "$INSTALL_DIR" 2>/dev/null || true
    printf '%s\n%s\n%s\n' "$daily_cost_usd" "$(date +%s)" "$today_local" \
      > "$daily_cache_file" 2>/dev/null || true
  fi
fi

# --- Helper: format cost with color ---
# Session vs daily spending have very different distributions — sessions are
# usually small with a long tail; daily totals are the aggregate.
format_cost() {
  local cost=$1
  local kind=${2:-session}  # session | daily
  local yellow_at red_at
  case "$kind" in
    daily)  yellow_at=200; red_at=400 ;;
    *)      yellow_at=75;  red_at=150 ;;
  esac
  local formatted
  formatted=$(printf '%s%.2f' "$currency_symbol" "$cost")
  local cost_int=${cost%.*}
  if (( cost_int >= red_at )); then
    printf '%b%s%b' "$RED" "$formatted" "$RESET"
  elif (( cost_int >= yellow_at )); then
    printf '%b%s%b' "$YELLOW" "$formatted" "$RESET"
  else
    printf '%s' "$formatted"
  fi
}

# --- Helper: colored progress bar ---
make_bar() {
  local pct=$1
  local width=${2:-10}
  if (( pct > 100 )); then pct=100; fi
  if (( pct < 0 )); then pct=0; fi
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local bar_color
  if (( pct >= 90 )); then bar_color="$RED"
  elif (( pct >= 70 )); then bar_color="$YELLOW"
  else bar_color="$GREEN"; fi
  local bar
  bar=$(printf "%${filled}s" | tr ' ' '█')$(printf "%${empty}s" | tr ' ' '░')
  printf '%b%s%b' "$bar_color" "$bar" "$RESET"
}

# --- Helper: reduce a branch or worktree name to its comparable core ---
# The same piece of work reaches the branch and the folder through different
# tools, each with its own idea of a legal name: `claude -w` can't put a slash
# in a branch, so a launcher asking for `gb/fix/x` lands on the folder
# `gb+fix+x` and the branch `worktree-gb+fix+x`, which a start hook later
# renames back to `gb/fix/x`. Folding `/` and `+` to one separator and dropping
# the `worktree-` marker makes those spellings compare equal without any
# configuration, which is what keeps line 2 from printing the same name twice.
normalize_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|^worktree-||; s|[/+]|-|g; s|-+|-|g; s|^-||; s|-$||'
}

# --- Helper: drop a configured prefix for display ---
# Entries in STATUSLINE_IGNORE_PREFIXES are glob patterns anchored at the
# start, so one `gb/*/` covers every category in a `gb/<category>/<slug>`
# convention. $prefix is deliberately unquoted in both the test and the
# expansion — quoting it would match the wildcard literally and defeat the
# point.
strip_ignored_prefix() {
  local name=$1
  local prefix stripped
  if (( ${#ignore_prefixes[@]} == 0 )); then
    printf '%s' "$name"
    return
  fi
  for prefix in "${ignore_prefixes[@]}"; do
    if [[ "$name" == $prefix* ]]; then
      stripped=${name#$prefix}
      # A pattern that would eat the whole name leaves nothing to identify the
      # worktree by, so that entry is skipped rather than blanking the line.
      if [[ -n "$stripped" ]]; then
        printf '%s' "$stripped"
        return
      fi
    fi
  done
  printf '%s' "$name"
}

# --- Get repo name and worktree ---
# One rev-parse yields all three facts: the checkout root, the shared repo
# directory, and this checkout's own git dir. A linked worktree is exactly the
# case where the last two differ — its git dir lives under
# <common>/worktrees/<name> while the common dir stays with the main checkout.
repo_name=""
in_git_repo=false
in_worktree=false
worktree_name=""
toplevel=""
git_common_dir=""
git_dir=""
git_facts=""
if [[ -n "$cwd" ]]; then
  git_facts=$(git -C "$cwd" rev-parse --show-toplevel --git-common-dir --git-dir 2>/dev/null || true)
fi
if [[ -z "$git_facts" && -z "$cwd" ]]; then
  git_facts=$(git rev-parse --show-toplevel --git-common-dir --git-dir 2>/dev/null || true)
fi
if [[ -n "$git_facts" ]]; then
  toplevel=$(printf '%s\n' "$git_facts" | sed -n '1p')
  git_common_dir=$(printf '%s\n' "$git_facts" | sed -n '2p')
  git_dir=$(printf '%s\n' "$git_facts" | sed -n '3p')
fi
if [[ -n "$toplevel" ]]; then
  repo_name=$(basename "$toplevel")
  in_git_repo=true
  # `--git-common-dir` can come back relative (plain ".git" in the main
  # checkout), so resolve it against the checkout root before comparing —
  # otherwise every main checkout would look like a linked worktree.
  if [[ -n "$git_common_dir" && "$git_common_dir" != /* ]]; then
    git_common_dir="${toplevel}/${git_common_dir}"
  fi
  if [[ -n "$git_dir" && "$git_dir" != /* ]]; then
    git_dir="${toplevel}/${git_dir}"
  fi
  if [[ -n "$git_common_dir" && -n "$git_dir" && "$git_common_dir" != "$git_dir" ]]; then
    in_worktree=true
    worktree_name="$repo_name"
    # The repo's real name is the main checkout's folder, one level above the
    # shared .git — without this, line 1 would name the worktree instead and
    # several concurrent worktrees would be indistinguishable from each other.
    # Only when the common dir is a conventional ".git" folder — a bare repo's
    # common dir is the repo itself (…/foo.git), whose parent names the
    # containing folder rather than the repo, so keep the worktree name there.
    if [[ "$(basename "$git_common_dir")" == ".git" ]]; then
      main_name=$(basename "$(dirname "$git_common_dir")")
      [[ -n "$main_name" && "$main_name" != "." && "$main_name" != "/" ]] && repo_name="$main_name"
    fi
  fi
elif [[ -n "$cwd" ]]; then
  # Fallback: not in a git repo, show the current folder name (handles paths with spaces)
  repo_name=$(basename "$cwd")
else
  # Fallback: cwd unset and not in a git repo, use the process working directory
  current_dir=$(pwd -P 2>/dev/null || pwd 2>/dev/null || true)
  [[ -n "$current_dir" ]] && repo_name=$(basename "$current_dir")
fi

# --- Determine terminal width (for branch truncation) ---
term_width=${COLUMNS:-0}
if (( term_width == 0 )); then
  term_width=$(tput cols 2>/dev/null || echo 100)
fi

# Budget for the dedicated branches line: emoji(2) + space(1) + a small safety margin.
branch_line_budget=$(( term_width - 3 - 2 ))
if (( branch_line_budget < 20 )); then branch_line_budget=20; fi

# --- Prefixes to hide from the displayed name ---
# Comma-separated, empty by default. Each entry is a glob anchored at the start
# of the name, so a `gb/<category>/<slug>` convention needs one `gb/*/` rather
# than a row per category.
ignore_prefixes=()
if [[ -n "${STATUSLINE_IGNORE_PREFIXES:-}" ]]; then
  IFS=',' read -r -a raw_ignore_prefixes <<< "${STATUSLINE_IGNORE_PREFIXES}"
  for raw_prefix in "${raw_ignore_prefixes[@]:-}"; do
    # Trim surrounding whitespace so "gb/*/, worktree-" is as valid as
    # "gb/*/,worktree-", and drop the empties a trailing comma leaves behind.
    raw_prefix="${raw_prefix#"${raw_prefix%%[![:space:]]*}"}"
    raw_prefix="${raw_prefix%"${raw_prefix##*[![:space:]]}"}"
    [[ -n "$raw_prefix" ]] && ignore_prefixes+=("$raw_prefix")
  done
fi

# --- Worktree + branch (rendered alone on its own line) ---
# Composed as one string so the width check lives in one place: this line must
# never wrap, and both parts share a single budget.
branch_info=""
current_branch=$(git -C "${cwd:-.}" branch --show-current 2>/dev/null || echo "")

worktree_part=""
branch_part=""
if [[ "$in_worktree" == "true" && -n "$worktree_name" ]]; then
  # A worktree is named after its branch or the branch after the worktree, so
  # printing both would spend half the line saying the same thing twice. Compare
  # the normalized cores, which sees through the separator and `worktree-`
  # differences the various tools introduce.
  branch_core=$(normalize_name "$current_branch")
  worktree_core=$(normalize_name "$worktree_name")
  if [[ -n "$current_branch" && -n "$branch_core" && -n "$worktree_core" \
        && ( "$branch_core" == "$worktree_core" \
             || "$branch_core" == *"$worktree_core"* \
             || "$worktree_core" == *"$branch_core"* ) ]]; then
    # The 🌳 alone carries "this is a worktree". Show the branch: it is the name
    # that was chosen for the work, where the folder is whatever the tool that
    # created the worktree was able to spell.
    worktree_part=$(strip_ignored_prefix "$current_branch")
  else
    # Unrelated names, or a detached HEAD (empty branch) where the worktree
    # name is the only handle on where this session is working. The branch keeps
    # its prefix here — when the two disagree, the prefix is the part worth
    # seeing.
    worktree_part="$worktree_name"
    branch_part="$current_branch"
  fi
elif [[ -n "$current_branch" ]]; then
  branch_part="$current_branch"
fi

if [[ -n "$worktree_part" && -n "$branch_part" ]]; then
  # Both parts present: the separator and the second emoji come out of the
  # budget too. The worktree name is what tells concurrent sessions apart, so
  # the branch is what gives up characters.
  pair_overhead=$(( 3 + 2 + 1 ))   # " · " plus the second emoji and its space
  branch_budget=$(( branch_line_budget - pair_overhead - ${#worktree_part} ))
  if (( branch_budget < 8 )); then
    # Not enough room left for a branch name that still means anything.
    branch_part=""
  elif (( ${#branch_part} > branch_budget )); then
    branch_part="${branch_part:0:$((branch_budget - 1))}…"
  fi
fi

if (( ${#worktree_part} > branch_line_budget )); then
  worktree_part="${worktree_part:0:$((branch_line_budget - 1))}…"
fi
if [[ -z "$worktree_part" ]] && (( ${#branch_part} > branch_line_budget )); then
  branch_part="${branch_part:0:$((branch_line_budget - 1))}…"
fi

if [[ -n "$worktree_part" && -n "$branch_part" ]]; then
  branch_info="🌳 ${worktree_part} · 🔀 ${branch_part}"
elif [[ -n "$worktree_part" ]]; then
  branch_info="🌳 ${worktree_part}"
elif [[ -n "$branch_part" ]]; then
  branch_info="🔀 ${branch_part}"
fi

# --- Model display ---
model_display=""
if [[ -n "$model_name" ]]; then
  model_display="🤖 ${model_name}"
fi

# --- Effort level ---
effort_display=""
if [[ -n "$effort_level" ]]; then
  case "$effort_level" in
    low)       effort_display=$(printf '⚡ %b%s%b' "$DIM" "$effort_level" "$RESET") ;;
    medium)    effort_display="⚡ ${effort_level}" ;;
    high)      effort_display=$(printf '⚡ %b%s%b' "$YELLOW" "$effort_level" "$RESET") ;;
    xhigh|max) effort_display=$(printf '⚡ %b%s%b' "$RED" "$effort_level" "$RESET") ;;
    *)         effort_display="⚡ ${effort_level}" ;;
  esac
fi

# --- Thinking flag ---
thinking_display=""
if [[ "$thinking_enabled" == "true" ]]; then
  thinking_display="🤔"
fi

# --- Session cost (convert USD to local currency) ---
session_cost_local=""
if [[ "$session_cost_usd" != "0" && "$session_cost_usd" != "null" ]]; then
  session_cost_val=$(echo "$session_cost_usd $currency_rate" | awk '{printf "%.2f", $1 * $2}')
  session_cost_local="💸 $(format_cost "$session_cost_val") session"
fi

# --- Daily cost (convert USD to local currency) ---
daily_cost_display=""
if [[ -n "$daily_cost_usd" && "$daily_cost_usd" != "0" && "$daily_cost_usd" != "0.0000" && "$daily_cost_usd" != "null" ]]; then
  daily_cost_val=$(echo "$daily_cost_usd $currency_rate" | awk '{printf "%.2f", $1 * $2}')
  daily_cost_display="💰 $(format_cost "$daily_cost_val" daily) today"
fi

# --- Rate limit bar ---
rate_display=""
if [[ -n "$five_hour_pct" && "$five_hour_pct" != "null" ]]; then
  pct_int=${five_hour_pct%.*}
  bar=$(make_bar "$pct_int" 10)
  time_left=""
  if [[ -n "$five_hour_resets" && "$five_hour_resets" != "null" ]]; then
    now=$(date +%s)
    remaining=$(( ${five_hour_resets%.*} - now ))
    if (( remaining > 0 )); then
      hours_left=$(( remaining / 3600 ))
      mins_left=$(( (remaining % 3600) / 60 ))
      time_left=" ${hours_left}h${mins_left}m left"
    fi
  fi
  rate_display="⏱️ ${bar} ${pct_int}%${time_left}"
elif [[ "$duration_ms" != "0" && "$duration_ms" != "null" ]]; then
  duration_secs=$(( ${duration_ms%.*} / 1000 ))
  # Only show duration if session has actually been running (> 0 seconds)
  if (( duration_secs > 0 )); then
    hours=$(( duration_secs / 3600 ))
    mins=$(( (duration_secs % 3600) / 60 ))
    rate_display="⏱️ ${hours}h${mins}m"
  fi
fi

# --- Context + tokens (hide when session hasn't started yet) ---
ctx_display=""
if [[ "$ctx_size" != "0" && "$ctx_size" != "null" ]]; then
  ctx_int=${ctx_pct%.*}
  # Only show context bar if there's actual usage
  if (( ctx_int > 0 )); then
    ctx_bar=$(make_bar "$ctx_int" 10)
    ctx_display="💭 ${ctx_bar} ${ctx_int}% ctx"
  fi
fi

token_display=""
if [[ "$total_input" != "0" && "$total_input" != "null" && "${total_input%.*}" -gt 0 ]]; then
  in_k=$(( ${total_input%.*} / 1000 ))
  out_k=$(( ${total_output%.*} / 1000 ))
  token_display="🧠 ${in_k}k in / ${out_k}k out"
fi

# --- Build multi-line output ---
# Line 1: Folder + model — folder, model name, effort, thinking flag
line1_parts=()
if [[ -n "$repo_name" ]]; then
  if [[ "$in_git_repo" == "true" ]]; then
    line1_parts+=("📂 ${repo_name}")
  else
    line1_parts+=("📁 ${repo_name}")
    line1_parts+=("$(printf '%b🚫 no git%b' "$DIM" "$RESET")")
  fi
fi
[[ -n "$model_display" ]] && line1_parts+=("$model_display")
[[ -n "$effort_display" ]] && line1_parts+=("$effort_display")
[[ -n "$thinking_display" ]] && line1_parts+=("$thinking_display")

# Line 2: Worktree + branch (alone — gets the full terminal width)
line2_parts=()
[[ -n "$branch_info" ]] && line2_parts+=("$branch_info")

# Line 3: Spend & limits — session cost, daily cost, rate limit
line3_parts=()
[[ -n "$session_cost_local" ]] && line3_parts+=("$session_cost_local")
[[ -n "$daily_cost_display" ]] && line3_parts+=("$daily_cost_display")
[[ -n "$rate_display" ]] && line3_parts+=("$rate_display")

# Line 4: Technical — context, tokens
line4_parts=()
[[ -n "$ctx_display" ]] && line4_parts+=("$ctx_display")
[[ -n "$token_display" ]] && line4_parts+=("$token_display")

# Join parts within each line
join_parts() {
  local sep=" · "
  local result=""
  for part in "$@"; do
    if [[ -n "$result" ]]; then
      result="${result}${sep}${part}"
    else
      result="$part"
    fi
  done
  echo "$result"
}

output=""
if (( ${#line1_parts[@]} > 0 )); then
  output+=$(join_parts "${line1_parts[@]}")
fi
if (( ${#line2_parts[@]} > 0 )); then
  [[ -n "$output" ]] && output+=$'\n'
  output+=$(join_parts "${line2_parts[@]}")
fi
if (( ${#line3_parts[@]} > 0 )); then
  [[ -n "$output" ]] && output+=$'\n'
  output+=$(join_parts "${line3_parts[@]}")
fi
if (( ${#line4_parts[@]} > 0 )); then
  [[ -n "$output" ]] && output+=$'\n'
  output+=$(join_parts "${line4_parts[@]}")
fi

echo -e "$output"
