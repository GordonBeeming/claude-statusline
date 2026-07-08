#!/usr/bin/env bash
set -euo pipefail

# Renders the per-teammate rows in Claude Code's agent panel (the
# `subagentStatusLine` setting). Each running teammate becomes:
#
#   ↳ 🐝 <label> · <model-glyph> <Model> · ↓ <tok> tok
#
# The bee marks a spawned worker; ↳ nests it under the main session. Only
# actively-running teammates are shown — finished/idle rows are hidden by
# emitting an empty content string, so the panel stays quiet once work is done.
#
# The payload's `tasks[]` has no model field, so the model is read from each
# teammate's own transcript (`<session>/subagents/agent-<id>.jsonl`). No network,
# no auto-update — this runs on every panel refresh tick and must stay fast.

stdin_data=$(cat)

# transcript_path is the MAIN session file: <session>.jsonl. The teammates live
# beside it under <session>/subagents/agent-<id>.jsonl.
transcript_path=$(printf '%s' "$stdin_data" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
columns=$(printf '%s' "$stdin_data" | jq -r '.columns // 80' 2>/dev/null || echo 80)
[[ "$columns" =~ ^[0-9]+$ ]] || columns=80
subagents_dir="${transcript_path%.jsonl}/subagents"

# Family → glyph. Glyph is per model family, not per price tier, so a substring
# test is enough. Fable and Mythos share a glyph (same top tier).
model_glyph() {
  case "$1" in
    *opus*)          printf '🦉' ;;
    *sonnet*)        printf '🔮' ;;
    *haiku*)         printf '🍃' ;;
    *fable*|*mythos*) printf '📖' ;;
    *)               printf '' ;;
  esac
}

# Raw model id → friendly name, e.g. claude-opus-4-8 → "Opus 4.8",
# claude-haiku-4-5-20251001 → "Haiku 4.5", claude-3-5-haiku-… → "Haiku 3.5".
# Current ids put the family before the version; legacy Haiku 3/3.5 ids put it
# after. Both forms are handled; the trailing date (if any) is dropped because
# the version capture only takes the first one or two numeric groups.
model_pretty() {
  local id="${1#claude-}" family="" ver=""
  if [[ "$id" =~ ^(opus|sonnet|haiku|fable|mythos)-([0-9]+(-[0-9]+)?) ]]; then
    family="${BASH_REMATCH[1]}"; ver="${BASH_REMATCH[2]}"
  elif [[ "$id" =~ ^([0-9]+(-[0-9]+)?)-(opus|sonnet|haiku|fable|mythos) ]]; then
    ver="${BASH_REMATCH[1]}"; family="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  ver="${ver//-/.}"
  # Title-case the family word. Done with tr rather than ${family^} so it works
  # on the bash 3.2 that ships with macOS (case modification is bash 4+).
  local first rest
  first=$(printf '%s' "${family:0:1}" | tr '[:lower:]' '[:upper:]')
  rest="${family:1}"
  printf '%s%s %s' "$first" "$rest" "$ver"
}

# Last assistant model recorded in a teammate's transcript. Empty if the file is
# missing or no assistant turn has landed yet (a just-spawned agent).
model_of() {
  local id="$1" file="${subagents_dir}/agent-${id}.jsonl"
  [[ -f "$file" ]] || return 0
  grep -oE '"model":"claude[^"]*"' "$file" 2>/dev/null \
    | tail -1 \
    | sed -E 's/.*"model":"//; s/"$//' || true
}

# Token count → compact display (36667 → "36.7k", 812 → "812").
fmt_tokens() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n >= 1000 )); then
    awk -v n="$n" 'BEGIN { printf "%.1fk", n/1000 }'
  else
    printf '%s' "$n"
  fi
}

# Walk the tasks. `label` is the human name shown (cmux teammate name); it falls
# back to description. Tab-separated so the bash loop can split cleanly.
tasks_tsv=$(printf '%s' "$stdin_data" | jq -r '
  .tasks // []
  | .[]
  | [ .id, (.status // ""), (.label // .description // ""), ((.tokenCount // 0) | tostring) ]
  | @tsv
' 2>/dev/null || true)

[[ -z "$tasks_tsv" ]] && exit 0

while IFS=$'\t' read -r id status label tok; do
  [[ -z "$id" ]] && continue

  # Only actively-running teammates get a row; everything else is hidden.
  if [[ "$status" != "running" ]]; then
    jq -cn --arg id "$id" '{id:$id, content:""}'
    continue
  fi

  content="↳ 🐝 ${label}"

  raw_model=$(model_of "$id")
  if [[ -n "$raw_model" ]]; then
    glyph=$(model_glyph "$raw_model")
    if pretty=$(model_pretty "$raw_model"); then
      if [[ -n "$glyph" ]]; then
        content="${content} · ${glyph} ${pretty}"
      else
        content="${content} · ${pretty}"
      fi
    fi
  fi

  content="${content} · ↓ $(fmt_tokens "$tok") tok"

  # Guard against overrunning the row width. Emoji count as one char here but
  # render wider, so this is a conservative safety net; the rows are short
  # enough that it rarely triggers.
  if (( ${#content} > columns )); then
    content="${content:0:$((columns - 1))}…"
  fi

  jq -cn --arg id "$id" --arg content "$content" '{id:$id, content:$content}'
done <<< "$tasks_tsv"
