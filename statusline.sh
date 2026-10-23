#!/usr/bin/env bash
#
# claude-code-statusline — a two-line statusline for Claude Code.
#
#   dotfiles · main ↑2 ●  Opus 5 (1M)  $1.24  +142/−38  12m
#   ctx [████████░░░░] 64% 640K/1M   5h [██░░░░░░] 24% ⟳14:32   7g [███░░░░░] 47%
#
# Every value comes from the JSON Claude Code writes to this script's stdin:
# no network calls, no credentials read, no cache on disk. One `jq` and one
# `git` per render, and neither is allowed to break the line if it fails.
#
# Requires: bash 4.2+, jq. git is optional (branch info is simply omitted).
#
# Install:
#   cp statusline.sh ~/.claude/statusline.sh && chmod +x ~/.claude/statusline.sh
#   then add to ~/.claude/settings.json:
#     "statusLine": { "type": "command", "command": "bash ~/.claude/statusline.sh" }
#
# Tuning: every knob below can also be overridden from the environment,
# e.g. "command": "BAR_W_CTX=20 bash ~/.claude/statusline.sh"
#
# Licence: MIT

# ---------------------------------------------------------------- tuning
BAR_W_CTX=${BAR_W_CTX:-10}      # context bar: 10 cells, so one cell = 10%
BAR_W_LIM=${BAR_W_LIM:-10}      # rate-limit bars: same metre, so all three read alike
T_MEDIUM=${T_MEDIUM:-50}        # >= this %: yellow
T_WARN=${T_WARN:-75}            # >= this %: orange
T_CRIT=${T_CRIT:-90}            # >= this %: red
G_FILL=${G_FILL:-█}
G_EMPTY=${G_EMPTY:-░}

# ---------------------------------------------------------------- colours
if [[ -n ${NO_COLOR:-} ]]; then
    C_OFF='' C_DIM='' C_TRACK='' C_TEXT=''
    C_GREEN='' C_YELLOW='' C_ORANGE='' C_RED=''
else
    C_OFF=$'\033[0m'
    C_DIM=$'\033[38;5;245m'      # labels and separators
    C_TRACK=$'\033[38;5;238m'    # unfilled part of a bar
    C_TEXT=$'\033[38;5;252m'     # ordinary text
    C_GREEN=$'\033[38;5;77m'
    C_YELLOW=$'\033[38;5;221m'
    C_ORANGE=$'\033[38;5;208m'
    C_RED=$'\033[38;5;203m'
fi

# ---------------------------------------------------------------- helpers

# Colour for a fill percentage. Sets $CUR rather than echoing, to keep the
# render free of subshells.
set_colour() {
    if   (( $1 >= T_CRIT ));   then CUR=$C_RED
    elif (( $1 >= T_WARN ));   then CUR=$C_ORANGE
    elif (( $1 >= T_MEDIUM )); then CUR=$C_YELLOW
    else                            CUR=$C_GREEN
    fi
}

# render_bar LABEL PCT WIDTH [SUFFIX] -> appends a bar segment to $SEG
# A non-zero percentage always shows at least one cell, so "just started"
# never looks identical to "empty".
render_bar() {
    local label=$1 pct=$2 w=$3 suffix=${4:-}
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    local filled=$(( pct * w / 100 ))
    (( filled == 0 && pct > 0 )) && filled=1
    (( filled > w )) && filled=$w

    local fill='' track='' i
    for (( i = 0; i < filled; i++ )); do fill+=$G_FILL; done
    for (( i = filled; i < w; i++ )); do track+=$G_EMPTY; done

    set_colour "$pct"
    SEG="${C_DIM}${label} ${C_TEXT}[${CUR}${fill}${C_TRACK}${track}${C_TEXT}]${CUR} ${pct}%${C_OFF}"
    [[ -n $suffix ]] && SEG+=" ${C_DIM}${suffix}${C_OFF}"
}

# 1000000 -> 1M, 1500000 -> 1.5M, 200000 -> 200K, 950 -> 950
fmt_count() {
    local n=$1
    if (( n >= 1000000 )); then
        local m=$(( n / 1000000 )) r=$(( (n % 1000000) / 100000 ))
        if (( r == 0 )); then printf '%dM' "$m"; else printf '%d.%dM' "$m" "$r"; fi
    elif (( n >= 1000 )); then
        printf '%dK' $(( n / 1000 ))
    else
        printf '%d' "$n"
    fi
}

# milliseconds -> 45s / 12m / 1h23m
fmt_duration() {
    local s=$(( $1 / 1000 ))
    if   (( s < 60 ));   then printf '%ds' "$s"
    elif (( s < 3600 )); then printf '%dm' $(( s / 60 ))
    else                      printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
    fi
}

# HH:MM for an epoch, via the printf builtin (bash 4.2+) so we spawn nothing.
fmt_clock() { printf "%($2)T" "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- input
input=$(cat)
[[ -z ${input//[[:space:]]/} ]] && exit 0
command -v jq >/dev/null 2>&1 || { printf '%s\n' "statusline: jq not found"; exit 0; }

# One jq pass for every field, joined with US (0x1f). A tab would not do:
# tab is IFS whitespace, so bash would collapse the empty fields of an
# absent value and silently shift every column after it.
read -r -d '' FILTER <<'JQ'
def n: if . == null then "" else (floor | tostring) end;
def s: if . == null then "" else (tostring | gsub("[[:cntrl:]]"; " ")) end;
[ (.context_window.used_percentage         // null | n),
  (.context_window.context_window_size     // null | n),
  (.rate_limits.five_hour.used_percentage  // null | n),
  (.rate_limits.five_hour.resets_at        // null | n),
  (.rate_limits.seven_day.used_percentage  // null | n),
  (.model.display_name                     // null | s),
  (.workspace.current_dir                  // null | s),
  (.cost.total_cost_usd                    // null | s),
  (.cost.total_lines_added                 // null | n),
  (.cost.total_lines_removed               // null | n),
  (.cost.total_duration_ms                 // null | n),
  (.worktree.name                          // null | s)
] | join("\u001f")
JQ

tsv=$(jq -r "$FILTER" <<<"$input" 2>/dev/null) || exit 0
[[ -z $tsv ]] && exit 0
IFS=$'\x1f' read -r ctx_pct ctx_size l5_pct l5_reset l7_pct model dir cost added removed dur wt <<<"$tsv"

# ---------------------------------------------------------------- git
# A single `git status` yields branch, divergence and dirtiness at once.
branch='' ahead='' behind='' dirty=''
if [[ -n $dir && -d $dir ]]; then
    if gitout=$(cd "$dir" 2>/dev/null && git --no-optional-locks status --porcelain=v2 --branch 2>/dev/null); then
        while IFS= read -r line; do
            case $line in
                '# branch.head '*) branch=${line#'# branch.head '} ;;
                '# branch.ab '*)
                    ab=${line#'# branch.ab '}
                    ahead=${ab%% *}; ahead=${ahead#+}
                    behind=${ab##* }; behind=${behind#-}
                    ;;
                '#'*) ;;
                ?*) dirty=1 ;;
            esac
        done <<<"$gitout"
    fi
fi

# ---------------------------------------------------------------- line 1
parts=()
[[ -n $dir ]] && parts+=("${C_TEXT}${dir##*/}${C_OFF}")

if [[ -n $branch && $branch != '(detached)' ]]; then
    b="${C_GREEN}${branch}${C_OFF}"
    [[ -n $ahead  && $ahead  != 0 ]] && b+=" ${C_YELLOW}↑${ahead}${C_OFF}"
    [[ -n $behind && $behind != 0 ]] && b+=" ${C_YELLOW}↓${behind}${C_OFF}"
    [[ -n $dirty ]] && b+=" ${C_ORANGE}●${C_OFF}"
    parts+=("$b")
elif [[ $branch == '(detached)' ]]; then
    parts+=("${C_ORANGE}detached${C_OFF}")
fi

[[ -n $wt ]] && parts+=("${C_DIM}wt:${wt}${C_OFF}")
[[ -n $model ]] && parts+=("${C_TEXT}${model}${C_OFF}")
[[ -n $cost ]] && parts+=("${C_TEXT}$(printf '$%.2f' "$cost")${C_OFF}")

if [[ -n $added || -n $removed ]]; then
    parts+=("${C_GREEN}+${added:-0}${C_OFF}${C_DIM}/${C_OFF}${C_RED}−${removed:-0}${C_OFF}")
fi
[[ -n $dur && $dur != 0 ]] && parts+=("${C_DIM}$(fmt_duration "$dur")${C_OFF}")

line1=
for p in "${parts[@]}"; do
    [[ -n $line1 ]] && line1+="${C_DIM} · ${C_OFF}"
    line1+=$p
done

# ---------------------------------------------------------------- line 2
segs=()
if [[ -n $ctx_pct ]]; then
    detail=
    if [[ -n $ctx_size && $ctx_size != 0 ]]; then
        detail="$(fmt_count $(( ctx_size * ctx_pct / 100 )))/$(fmt_count "$ctx_size")"
    fi
    render_bar ctx "$ctx_pct" "$BAR_W_CTX" "$detail"
    segs+=("$SEG")
fi

if [[ -n $l5_pct ]]; then
    clock=
    if [[ -n $l5_reset ]] && (( l5_reset > $(printf '%(%s)T' -1) )); then
        clock="⟳$(fmt_clock "$l5_reset" '%H:%M')"
    fi
    render_bar 5h "$l5_pct" "$BAR_W_LIM" "$clock"
    segs+=("$SEG")
fi

if [[ -n $l7_pct ]]; then
    render_bar 7g "$l7_pct" "$BAR_W_LIM"
    segs+=("$SEG")
fi

line2=
for s in "${segs[@]}"; do
    [[ -n $line2 ]] && line2+="   "
    line2+=$s
done

# ---------------------------------------------------------------- output
[[ -n $line1 ]] && printf '%s\n' "$line1"
[[ -n $line2 ]] && printf '%s\n' "$line2"
exit 0
