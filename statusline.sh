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
  @sh "five_hour_resets=\(.rate_limits.five_hour.resets_at // "")"
' 2>/dev/null || echo 'cwd=""; model_name=""; model_id=""; session_cost_usd=0; duration_ms=0; ctx_pct=0; ctx_size=0; total_input=0; total_output=0; five_hour_pct=""; five_hour_resets=""')"

# --- Get currency and daily cost from goccc ---
currency_symbol="$"
currency_rate=1
daily_cost=0
if command -v goccc &>/dev/null; then
  goccc_json=$(goccc -days 1 -json 2>/dev/null || echo '{}')
  currency_symbol=$(echo "$goccc_json" | jq -r '.currency.symbol // "$"' 2>/dev/null || echo '$')
  currency_rate=$(echo "$goccc_json" | jq -r '.currency.rate // 1' 2>/dev/null || echo 1)
  daily_cost=$(echo "$goccc_json" | jq -r '.summary.total_cost // 0' 2>/dev/null || echo 0)
fi

# --- Helper: format cost with color ---
format_cost() {
  local cost=$1
  local formatted
  formatted=$(printf '%s%.2f' "$currency_symbol" "$cost")
  # Color thresholds (in local currency)
  local cost_int=${cost%.*}
  if (( cost_int >= 50 )); then
    printf '%b%s%b' "$RED" "$formatted" "$RESET"
  elif (( cost_int >= 25 )); then
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
if [[ -n "$cwd" ]]; then
  repo_name=$(cd "$cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null || true)
fi
if [[ -z "$repo_name" ]] && git rev-parse --show-toplevel &>/dev/null; then
  repo_name=$(basename "$(git rev-parse --show-toplevel)")
fi

# --- Get branch info ---
branch_info=""
current_branch=$(git branch --show-current 2>/dev/null || echo "")
if [[ "$current_branch" == "gitbutler/workspace" ]]; then
  branches=""
  if command -v but &>/dev/null; then
    branches=$(but branch list --no-check --no-ahead --json 2>/dev/null \
      | jq -r '.appliedStacks[].heads[].name' 2>/dev/null \
      | paste -sd ',' - 2>/dev/null \
      | sed 's/,/, /g' || true)
  fi
  if [[ -n "$branches" ]]; then
    branch_info="🌿 ${branches}"
  else
    branch_info="🌿 gitbutler/workspace"
  fi
elif [[ -n "$current_branch" ]]; then
  branch_info="🔀 ${current_branch}"
fi

# --- Model display ---
model_display=""
if [[ -n "$model_name" ]]; then
  model_display="🤖 ${model_name}"
fi

# --- Session cost (convert USD to local currency) ---
session_cost_local=""
if [[ "$session_cost_usd" != "0" && "$session_cost_usd" != "null" ]]; then
  session_cost_val=$(echo "$session_cost_usd $currency_rate" | awk '{printf "%.2f", $1 * $2}')
  session_cost_local="💸 $(format_cost "$session_cost_val") session"
fi

# --- Daily cost ---
daily_cost_display=""
if [[ "$daily_cost" != "0" && "$daily_cost" != "null" ]]; then
  daily_cost_val=$(echo "$daily_cost $currency_rate" | awk '{printf "%.2f", $1 * $2}')
  daily_cost_display="💰 $(format_cost "$daily_cost_val") today"
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

# --- Set terminal tab title ---
if [[ -n "$repo_name" ]]; then
  printf '\033]0;%s\007' "$repo_name" >&2
fi

# --- Build multi-line output ---
# Line 1: Identity — repo, branch, model
line1_parts=()
[[ -n "$repo_name" ]] && line1_parts+=("📂 ${repo_name}")
[[ -n "$branch_info" ]] && line1_parts+=("$branch_info")
[[ -n "$model_display" ]] && line1_parts+=("$model_display")

# Line 2: Spend & limits — session cost, daily cost, rate limit
line2_parts=()
[[ -n "$session_cost_local" ]] && line2_parts+=("$session_cost_local")
[[ -n "$daily_cost_display" ]] && line2_parts+=("$daily_cost_display")
[[ -n "$rate_display" ]] && line2_parts+=("$rate_display")

# Line 3: Technical — context, tokens
line3_parts=()
[[ -n "$ctx_display" ]] && line3_parts+=("$ctx_display")
[[ -n "$token_display" ]] && line3_parts+=("$token_display")

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

echo -e "$output"
