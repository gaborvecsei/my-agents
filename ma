#!/usr/bin/env bash

set -euo pipefail

BOLD=$(tput bold 2>/dev/null || true)
DIM=$(tput dim 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
NORMAL=$(tput sgr0 2>/dev/null || true)

self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

usage() {
  cat <<EOF
ma - list running coding agents (Claude Code, pi) and jump to their tmux pane

Usage:
  ma                       open the picker: Enter jumps to the agent, ctrl-r refreshes
  ma --json                print every agent as JSON
  ma --rows                print one formatted row per agent
  ma --preview <pane-id>   print the last lines of a tmux pane
  ma -h, --help            show this help

Status:
  ● waiting for input   ▶ busy   ○ idle   ? unknown (pi outside tmux)

Agents that need input are listed first. Agents outside tmux are listed last
and cannot be jumped to.

Requires tmux and jq, plus fzf for the picker. Claude Code agents need the
claude CLI on PATH, and the branch column needs git.
EOF
}

die() {
  printf '%serror:%s %s\n' "$RED$BOLD" "$NORMAL" "$1" >&2
  exit 1
}

need() {
  local cmd
  for cmd; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing dependency: $cmd"
  done
}

pad() {
  printf '%s%*s' "$1" $(($2 > ${#1} ? $2 - ${#1} : 0)) ''
}

print_row() {
  printf '%s %-2s %s %s%s%s %s%s%s %s%s%s\n' \
    "$1" "$2" "$(pad "$3" 22)" "$DIM" "$(pad "$4" 30)" "$NORMAL" "$YELLOW" "$(pad "$5" 18)" "$NORMAL" "$DIM" "$6" "$NORMAL"
}

resolve_panes() {
  {
    ps -eo pid=,ppid= | awk '{ print "proc", $1, $2 }'
    tmux list-panes -a -F 'pane #{pane_pid} #{pane_id} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true
    awk '{ print "agent", $0 }'
  } | awk '
    $1 == "proc" { parent[$2] = $3; next }
    $1 == "pane" { pane[$2] = $3; loc[$2] = $0; sub(/^pane [^ ]+ [^ ]+ /, "", loc[$2]); next }
    $1 == "agent" {
      sub(/^agent /, "")
      for (p = $1; p != "" && p != "1"; p = parent[p])
        if (p in pane) { print pane[p] "\t" loc[p] "\t" $0; next }
      print "-\t-\t" $0
    }'
}

records_claude() {
  claude agents --json 2>/dev/null \
    | jq -r '.[] | select(.kind == "interactive") | "\(.pid)\tcc\t\(.status | if . == "shell" then "busy" else . end)\t\(.name)\t\(.cwd)"' 2>/dev/null \
    | resolve_panes
}

proc_cwd() {
  if [[ -r "/proc/$1/cwd" ]]; then
    readlink "/proc/$1/cwd" || echo "-"
  else
    lsof -a -p "$1" -d cwd -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }' || echo "-"
  fi
}

pane_lines() {
  tmux capture-pane -p "$@" 2>/dev/null | awk 'NF { while (n) { print ""; n-- } print; next } { n++ }'
}

pi_status() {
  local screen
  screen=$(pane_lines -t "$1" | tail -20)
  if grep -qiE '↑.?↓ *(to )?navigate|enter (to )?(select|submit|save|confirm)( |$)|project trust|✓ submit' <<<"$screen"; then
    echo waiting
  elif grep -qE '⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏' <<<"$screen"; then
    echo busy
  else
    echo idle
  fi
}

records_pi() {
  local pane loc pid cwd status name title
  ps -eo pid=,tty=,comm= \
    | awk '$3 == "pi" && $2 !~ /^\?+$/ { print $1 }' \
    | resolve_panes \
    | while IFS=$'\t' read -r pane loc pid; do
        cwd=$(proc_cwd "$pid")
        name=$(basename "$cwd")
        status=unknown
        if [[ "$pane" != "-" ]]; then
          status=$(pi_status "$pane")
          title=$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null) || true
          if [[ "$title" == "π - "* ]]; then
            name=${title#"π - "}
          fi
        fi
        printf '%s\t%s\t%s\tpi\t%s\t%s\t%s\n' "$pane" "$loc" "$pid" "$status" "$name" "$cwd"
      done
}

records() {
  { records_claude || true; records_pi; } \
    | awk -F'\t' '{ print ($5 == "waiting" ? 0 : $5 == "busy" ? 1 : 2) + ($1 == "-" ? 3 : 0) "\t" $0 }' \
    | sort -t$'\t' -k1,1n -k3,3 \
    | cut -f2-
}

json() {
  records | jq -nR '[inputs | split("\t") | {
    agent:    .[3],
    status:   .[4],
    name:     .[5],
    cwd:      .[6],
    pane:     (.[0] | if . == "-" then null else . end),
    location: (.[1] | if . == "-" then null else . end)
  }]'
}

rows() {
  local pane loc agent status name cwd glyph branch dir
  records | while IFS=$'\t' read -r pane loc _ agent status name cwd; do
    case "$status" in
      waiting) glyph="${RED}●${NORMAL}" ;;
      busy) glyph="${GREEN}▶${NORMAL}" ;;
      unknown) glyph="${DIM}?${NORMAL}" ;;
      *) glyph="${DIM}○${NORMAL}" ;;
    esac
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null) || true
    dir=$cwd
    if [[ "$dir" == "$HOME" || "$dir" == "$HOME"/* ]]; then
      dir="~${dir#"$HOME"}"
    fi
    if [[ "$loc" == "-" ]]; then
      loc="(not in tmux)"
    fi
    printf '%s\t' "$pane"
    print_row "$glyph" "$agent" "$name" "$loc" "${branch:--}" "$dir"
  done
}

# Popups have no TMUX_PANE, so without -c tmux switches the most recently active client.
# $TMUX ends with the id of the session we were started from.
own_client() {
  tmux list-clients -t "\$${TMUX##*,}" -F '#{client_activity} #{client_name}' | sort -rn | awk 'NR == 1 { print $2 }'
}

jump() {
  local pane=$1
  [[ "$pane" != "-" ]] || die "that agent does not run inside tmux, nothing to jump to"
  tmux select-window -t "$pane" 2>/dev/null || die "pane $pane is gone (agent exited?), run ma again to refresh"
  tmux select-pane -t "$pane"
  if [[ -n "${TMUX-}" ]]; then
    tmux switch-client -c "$(own_client)" -t "$pane"
  else
    tmux attach-session -t "$pane"
  fi
}

pick() {
  local cmd choice
  cmd=$(printf '%q' "$self")
  choice=$(rows | fzf --ansi --delimiter='\t' --with-nth=2.. --reverse \
    --prompt='agent> ' --header="$(DIM='' YELLOW='' NORMAL='' print_row " " ai name "session:window.pane" branch dir)" \
    --preview="$cmd --preview {1}" --preview-window=down,60%,border-top \
    --bind="ctrl-r:reload($cmd --rows)" \
    | cut -f1) || true
  [[ -z "$choice" ]] || jump "$choice"
}

case "${1-}" in
  "")
    need tmux jq fzf
    pick
    ;;
  --json)
    need tmux jq
    json
    ;;
  --rows)
    need tmux jq
    rows
    ;;
  --preview)
    [[ -n "${2-}" && "$2" != "-" ]] || { echo "no tmux pane"; exit 0; }
    pane_lines -e -t "$2" | tail -n "${FZF_PREVIEW_LINES:-40}" || echo "pane is gone"
    ;;
  -h | --help)
    usage
    ;;
  *)
    die "unknown option: $1 (try --help)"
    ;;
esac
