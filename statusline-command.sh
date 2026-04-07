#!/bin/sh
#
# Claude Code status line — context, cost, and quota at a glance.
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/mhagmajer/claude-code-statusline/main/statusline-command.sh | sh -s -- --install
#
# Groups: Where | Engine | Activity | Quota
#   path  branch  +N -N  │  Opus 4.6 1M  ● 7%  │  ⏱24m  451⇡ 31k⇣  $2.59  │  5h ● 40%  3h44m  7d ● 11%
#
if [ "$1" = "--install" ]; then
  for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: $cmd is required but not found. Please install it first." >&2
      exit 1
    fi
  done
  SCRIPT_URL="https://raw.githubusercontent.com/mhagmajer/claude-code-statusline/main/statusline-command.sh"
  DEST="$HOME/.claude/statusline-command.sh"
  SETTINGS="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  curl -fsSL "$SCRIPT_URL" -o "$DEST" && chmod +x "$DEST"
  jq -n --argjson s "$(cat "$SETTINGS" 2>/dev/null || echo '{}')" \
    '$s + {"statusLine":{"type":"command","command":"bash ~/.claude/statusline-command.sh"}}' \
    > /tmp/cs.json && mv /tmp/cs.json "$SETTINGS"
  echo "Installed: $DEST"
  echo "Updated:   $SETTINGS"
  echo "Takes effect on the next Claude Code session."
  exit 0
fi

input=$(cat)

# ── Parse fields ──
cwd=$(echo "$input" | jq -r '.cwd')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')
model_id=$(echo "$input" | jq -r '.model.id // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
lines_add=$(echo "$input" | jq -r '.cost.total_lines_added // empty')
lines_del=$(echo "$input" | jq -r '.cost.total_lines_removed // empty')
dur_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
five_hr=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# ── Colors ──
red="\033[31m"
yellow="\033[33m"
green="\033[32m"
cyan="\033[36m"
magenta="\033[35m"
dim="\033[2m"
bold="\033[1m"
reset="\033[0m"
sep="${dim}│${reset}"

# Smooth green→yellow→red gradient using 256-color (11 steps)
# Input: percentage 0-100 where 0=good(green) 100=bad(red)
gradient() {
  pct=$1
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  idx=$(( pct * 10 / 100 ))
  case $idx in
    0) c=46 ;; 1) c=82 ;; 2) c=118 ;; 3) c=154 ;; 4) c=190 ;;
    5) c=226 ;; 6) c=220 ;; 7) c=214 ;; 8) c=208 ;; 9) c=202 ;; *) c=196 ;;
  esac
  printf "\033[38;5;%dm" "$c"
}

dot() {
  printf "%b●${reset}" "$(gradient "$1")"
}

fmt_tok() {
  t=$1
  if [ -z "$t" ] || [ "$t" = "0" ]; then printf "0"; return; fi
  if [ "$t" -ge 1000000 ]; then
    printf "%s" "$(echo "$t" | awk '{v=$1/1000000; if(v==int(v)) printf "%dM",v; else printf "%.1fM",v}')"
  elif [ "$t" -ge 1000 ]; then
    printf "%.0fk" "$(echo "$t" | awk '{printf "%.0f", $1/1000}')"
  else
    printf "%d" "$t"
  fi
}

fmt_dur() {
  ms=$1
  total_s=$(( ms / 1000 ))
  if [ "$total_s" -lt 60 ]; then printf "%ds" "$total_s"
  elif [ "$total_s" -lt 3600 ]; then printf "%dm" $(( total_s / 60 ))
  else printf "%dh%dm" $(( total_s / 3600 )) $(( (total_s % 3600) / 60 )); fi
}

# ── Derived values ──

# Relative path
if [ -n "$project_dir" ] && [ "$project_dir" != "$cwd" ]; then
  relpath=$(echo "$cwd" | sed "s|^${project_dir}/||")
else
  relpath=$(basename "$cwd")
fi

# Git branch (shortened)
branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
short_branch=""
if [ -n "$branch" ]; then
  short_branch=$(echo "$branch" | sed 's|^[^/]*/||')
  if [ ${#short_branch} -gt 20 ]; then
    ticket=$(echo "$short_branch" | grep -oE '^[a-zA-Z]+-[0-9]+' | head -1)
    if [ -n "$ticket" ]; then short_branch="$ticket"
    else short_branch=$(echo "$short_branch" | cut -c1-18)..; fi
  fi
fi

# Model name with version
model_short=""
case "$model_id" in
  *opus*)   model_short="Opus" ;;
  *sonnet*) model_short="Sonnet" ;;
  *haiku*)  model_short="Haiku" ;;
  *)        model_short=$(echo "$input" | jq -r '.model.display_name // empty') ;;
esac
if [ -n "$model_short" ]; then
  ver=$(echo "$model_id" | grep -oE '[0-9]+-[0-9]+' | head -1 | tr '-' '.')
  if [ -n "$ver" ]; then model_short="${model_short} ${ver}"; fi
  # Append context window size (e.g. "1M", "200k")
  if [ -n "$ctx_size" ] && [ "$ctx_size" != "0" ]; then
    model_short="${model_short} $(fmt_tok "$ctx_size")"
  fi
fi

# ════════════════════════════════════════
# GROUP 1: Where — path, branch, lines changed
# ════════════════════════════════════════
printf "${bold}%s${reset}" "$relpath"
if [ -n "$short_branch" ]; then printf "  ${dim}⎇ %s${reset}" "$short_branch"; fi
if [ -n "$lines_add" ] && [ -n "$lines_del" ] && [ "$lines_add$lines_del" != "00" ]; then
  printf "  ${green}+%s${reset} ${red}-%s${reset}" "$lines_add" "$lines_del"
fi

# ════════════════════════════════════════
# GROUP 2: Engine — model + context window
# ════════════════════════════════════════
if [ -n "$model_short" ] || [ -n "$ctx_pct" ]; then
  printf "  %b  " "$sep"

  if [ -n "$model_short" ]; then printf "${cyan}%s${reset}" "$model_short"; fi

  if [ -n "$ctx_pct" ]; then
    ctx_int=$(printf '%.0f' "$ctx_pct")

    printf "  "

    # Dot + percentage, both gradient-colored
    printf "%b %b%s%%${reset}" "$(dot "$ctx_int")" "$(gradient "$ctx_int")" "$ctx_int"
  fi
fi

# ════════════════════════════════════════
# GROUP 3: Activity — usage → efficiency → cost
# ════════════════════════════════════════
has_activity=""
if [ -n "$dur_ms" ] && [ "$dur_ms" != "0" ]; then has_activity=1; fi
if [ -n "$cost" ] && [ "$cost" != "0" ]; then has_activity=1; fi
if [ -n "$total_input" ]; then has_activity=1; fi

if [ -n "$has_activity" ]; then
  printf "  %b  " "$sep"

  first_item=1

  # Duration
  if [ -n "$dur_ms" ] && [ "$dur_ms" != "0" ]; then
    printf "${dim}⏱%s${reset}" "$(fmt_dur "$dur_ms")"
    first_item=""
  fi

  # Tokens: cumulative input⇡ output⇣
  if [ -n "$total_input" ] || { [ -n "$total_output" ] && [ "$total_output" != "0" ]; }; then
    [ -z "$first_item" ] && printf "  "
    ti=${total_input:-0}
    to=${total_output:-0}
    if [ "$ti" != "0" ]; then
      printf "${dim}%s⇡${reset}" "$(fmt_tok "$ti")"
    fi
    if [ "$to" != "0" ]; then
      [ "$ti" != "0" ] && printf " "
      printf "${magenta}%s⇣${reset}" "$(fmt_tok "$to")"
    fi
    first_item=""
  fi

  # Cost (the bottom line — magenta like output, the main cost driver)
  if [ -n "$cost" ] && [ "$cost" != "0" ]; then
    [ -z "$first_item" ] && printf "  "
    printf "${magenta}\$%.2f${reset}" "$cost"
  fi
fi

# ════════════════════════════════════════
# GROUP 4: Quota — will I get throttled?
# ════════════════════════════════════════
if [ -n "$five_hr" ] || [ -n "$seven_day" ]; then
  printf "  %b  " "$sep"

  if [ -n "$five_hr" ]; then
    five_int=$(printf '%.0f' "$five_hr")
    printf "5h %b %s%%" "$(dot "$five_int")" "$five_int"

    if [ -n "$five_reset" ]; then
      now=$(date +%s)
      diff=$(( five_reset - now ))
      if [ "$diff" -gt 0 ]; then
        hrs=$(( diff / 3600 ))
        mins=$(( (diff % 3600) / 60 ))
        total_min=$((hrs * 60 + mins))
        # Map minutes remaining (0-300) to 0-100% for gradient
        # 0 min left = green (reset soon), 300 min = red (long wait)
        timer_pct=$(( total_min * 100 / 300 ))
        [ "$timer_pct" -gt 100 ] && timer_pct=100
        tc=$(gradient "$timer_pct")
        if [ "$hrs" -gt 0 ]; then printf "  ${tc}%dh%dm${reset}" "$hrs" "$mins"
        else printf "  ${tc}%dm${reset}" "$mins"; fi
      fi
    fi
  fi

  if [ -n "$seven_day" ]; then
    seven_int=$(printf '%.0f' "$seven_day")
    printf "   7d %b %s%%" "$(dot "$seven_int")" "$seven_int"
  fi
fi
