#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.claude/scripts"
INSTALLED_SCRIPT="${INSTALL_DIR}/statusline.sh"
UPDATE_MARKER="${INSTALL_DIR}/.statusline-last-update"
REPO_URL="https://raw.githubusercontent.com/gordonbeeming/claude-statusline/main/statusline.sh"

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
      tmp=$(mktemp)
      if curl -sSL --max-time 5 "$REPO_URL" -o "$tmp" 2>/dev/null; then
        if [[ -s "$tmp" ]] && head -1 "$tmp" | grep -q '^#!/'; then
          cp "$tmp" "$INSTALLED_SCRIPT"
          chmod +x "$INSTALLED_SCRIPT"
        fi
      fi
      rm -f "$tmp"
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
      # Pricing table — USD per 1M tokens. Source: https://www.anthropic.com/pricing
      # Buckets keyed by model family substring; 1h cache-write is 2x the 5m
      # rate per Anthropic's published rates. Legacy Claude 3 Haiku (e.g.
      # `claude-3-haiku-20240307`) gets its own branch — its rates are an
      # order of magnitude lower than 3.5/4-family Haiku. The 3.5 case is
      # matched *before* the legacy case so model IDs like
      # `claude-3-5-haiku-20241022` don't fall into the cheaper bucket.
      # Unknown models contribute 0 so a new release doesn't silently
      # inflate the total — update this table when new pricing lands.
      # Disable `pipefail` while running the pipeline so a half-written
      # `.jsonl` line aborting jq doesn't kill the script. We capture
      # jq's exit code via PIPESTATUS and only treat the result as a
      # successful recompute when jq itself returned 0.
      set +o pipefail
      jq_raw=$(jq -r --argjson lo "$day_lo" --argjson hi "$day_hi" '
        def model_rate($m):
          ($m | ascii_downcase) as $lm
          | if   ($lm | test("opus"))                  then {i:15,   o:75,   cw5:18.75, cw1h:30,   cr:1.50}
            elif ($lm | test("sonnet"))                then {i:3,    o:15,   cw5:3.75,  cw1h:6,    cr:0.30}
            elif ($lm | test("3-5-haiku|haiku-3-5"))   then {i:1,    o:5,    cw5:1.25,  cw1h:2.50, cr:0.10}
            elif ($lm | test("3-haiku|haiku-3"))       then {i:0.25, o:1.25, cw5:0.30,  cw1h:0.60, cr:0.03}
            elif ($lm | test("haiku"))                 then {i:1,    o:5,    cw5:1.25,  cw1h:2.50, cr:0.10}
            else null end;
        select(.timestamp != null and (.message.usage // null) != null and (.message.model // null) != null)
        | (((.timestamp[0:19] + "Z") | fromdateiso8601?) // 0) as $ts
        | select($ts >= $lo and $ts < $hi)
        | model_rate(.message.model) as $r
        | select($r != null)
        | .message.usage as $u
        | ((($u.input_tokens // 0)              * $r.i)
          + (($u.output_tokens // 0)            * $r.o)
          + (($u.cache_read_input_tokens // 0)  * $r.cr)
          + (if ($u.cache_creation // null) != null
               then (($u.cache_creation.ephemeral_5m_input_tokens // 0) * $r.cw5)
                  + (($u.cache_creation.ephemeral_1h_input_tokens // 0) * $r.cw1h)
               else (($u.cache_creation_input_tokens // 0) * $r.cw5)
             end)) / 1000000
      ' "${jsonl_files[@]}" 2>/dev/null)
      jq_exit=$?
      set -o pipefail
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

# --- Get repo name ---
repo_name=""
in_git_repo=false
toplevel=""
if [[ -n "$cwd" ]]; then
  toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
fi
if [[ -z "$toplevel" && -z "$cwd" ]]; then
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
if [[ -n "$toplevel" ]]; then
  repo_name=$(basename "$toplevel")
  in_git_repo=true
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

# --- Get branch info (rendered alone on its own line) ---
branch_info=""
current_branch=$(git branch --show-current 2>/dev/null || echo "")
if [[ "$current_branch" == "gitbutler/workspace" ]]; then
  branch_emoji="🌿"
  branch_names=()
  if command -v but &>/dev/null; then
    while IFS= read -r b; do
      [[ -n "$b" ]] && branch_names+=("$b")
    done < <(but branch list --no-check --no-ahead --json 2>/dev/null \
      | jq -r '.appliedStacks[].heads[].name' 2>/dev/null || true)
  fi
  branch_count=${#branch_names[@]}

  if (( branch_count == 0 )); then
    branch_info="${branch_emoji} gitbutler/workspace"
  elif (( branch_count == 1 )); then
    name="${branch_names[0]}"
    if (( ${#name} > branch_line_budget )); then
      name="${name:0:$((branch_line_budget - 1))}…"
    fi
    branch_info="${branch_emoji} ${name}"
  else
    # Pack as many full names as fit, then suffix " + N more" for the remainder.
    shown=""
    shown_count=0
    for name in "${branch_names[@]}"; do
      if [[ -n "$shown" ]]; then
        candidate="${shown}, ${name}"
      else
        candidate="${name}"
      fi
      remaining_after=$(( branch_count - shown_count - 1 ))
      suffix=""
      (( remaining_after > 0 )) && suffix=" + ${remaining_after} more"
      if (( ${#candidate} + ${#suffix} <= branch_line_budget )); then
        shown="$candidate"
        shown_count=$(( shown_count + 1 ))
      else
        break
      fi
    done
    if (( shown_count == 0 )); then
      # Even the first name doesn't fit — truncate it and summarise the rest.
      remaining_after=$(( branch_count - 1 ))
      suffix=" + ${remaining_after} more"
      first_budget=$(( branch_line_budget - ${#suffix} ))
      (( first_budget < 8 )) && first_budget=8
      first="${branch_names[0]}"
      if (( ${#first} > first_budget )); then
        first="${first:0:$((first_budget - 1))}…"
      fi
      branch_info="${branch_emoji} ${first}${suffix}"
    else
      remaining_after=$(( branch_count - shown_count ))
      if (( remaining_after > 0 )); then
        branch_info="${branch_emoji} ${shown} + ${remaining_after} more"
      else
        branch_info="${branch_emoji} ${shown}"
      fi
    fi
  fi
elif [[ -n "$current_branch" ]]; then
  truncated_branch="$current_branch"
  if (( ${#truncated_branch} > branch_line_budget )); then
    truncated_branch="${truncated_branch:0:$((branch_line_budget - 1))}…"
  fi
  branch_info="🔀 ${truncated_branch}"
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

# Line 2: Branches (alone — gets the full terminal width)
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
