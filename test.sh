#!/usr/bin/env bash
# Test suite for statusline.sh — pure JSON->text, so assertions are exact.
SCRIPT="${1:-$(dirname "$0")/statusline.sh}"
PASS=0; FAIL=0
NOW=$(date +%s)

run()  { NO_COLOR=1 bash "$SCRIPT" <<<"$1" 2>&1; }
runc() { bash "$SCRIPT" <<<"$1" 2>&1; }

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; printf '    got: %q\n' "$2"; }

has()    { local d="$1" o="$2" n="$3"; [[ "$o" == *"$n"* ]] && ok || bad "$d — expected to contain %s: $n" "$o"; }
hasnot() { local d="$1" o="$2" n="$3"; [[ "$o" != *"$n"* ]] && ok || bad "$d — expected NOT to contain: $n" "$o"; }
eq()     { local d="$1" a="$2" b="$3"; [[ "$a" == "$b" ]] && ok || bad "$d — expected '$b'" "$a"; }

# ---------------------------------------------------------------- fixtures
REPO=$(mktemp -d); git -C "$REPO" init -q -b main; git -C "$REPO" commit -q --allow-empty -m x
PLAIN=$(mktemp -d)

full=$(cat <<EOF
{"context_window":{"used_percentage":64,"context_window_size":1000000},
 "rate_limits":{"five_hour":{"used_percentage":24,"resets_at":$((NOW+3600))},
                "seven_day":{"used_percentage":47,"resets_at":$((NOW+86400))}},
 "model":{"display_name":"Opus 5 (1M)"},
 "workspace":{"current_dir":"$REPO"},
 "cost":{"total_cost_usd":1.2449,"total_lines_added":142,"total_lines_removed":38,"total_duration_ms":735000},
 "session_id":"abc"}
EOF
)
pct() { printf '{"context_window":{"used_percentage":%s,"context_window_size":200000},"workspace":{"current_dir":"%s"}}' "$1" "$PLAIN"; }

echo "== statusline tests =="

# 1. full render, both lines
o=$(run "$full")
has "full/ctx label"  "$o" "ctx ["
has "full/ctx pct"    "$o" "64%"
has "full/ctx tokens" "$o" "640K/1M"
has "full/5h"         "$o" "5h ["
has "full/5h pct"     "$o" "24%"
has "full/7d"         "$o" "7g ["
has "full/7d pct"     "$o" "47%"
has "full/model"      "$o" "Opus 5 (1M)"
has "full/cost"       "$o" '$1.24'
has "full/lines"      "$o" "+142"
has "full/lines-rm"   "$o" "38"
has "full/duration"   "$o" "12m"
has "full/branch"     "$o" "main"
has "full/dir"        "$o" "$(basename "$REPO")"
eq  "full/two lines"  "$(printf '%s' "$o" | wc -l)" "1"   # 2 lines => 1 newline

# 2. bar geometry: filled+empty always == width
for p in 0 1 49 50 64 99 100; do
  bar=$(run "$(pct $p)" | sed -n '2p' | sed 's/.*ctx \[\([^]]*\)\].*/\1/')
  eq "geometry/width p=$p" "${#bar}" "10"
done
eq "geometry/p=0 empty"   "$(run "$(pct 0)"   | grep -o '█' | wc -l)" "0"
eq "geometry/p=100 full"  "$(run "$(pct 100)" | grep -o '█' | wc -l)" "10"
eq "geometry/p=1 sliver"  "$(run "$(pct 1)"   | grep -o '█' | wc -l)" "1"

# 3. colour steps (thresholds 50 / 75 / 90)
GREEN=$'\033[38;5;77m'; YELLOW=$'\033[38;5;221m'; ORANGE=$'\033[38;5;208m'; RED=$'\033[38;5;203m'
has "colour/30 green"  "$(runc "$(pct 30)")" "$GREEN"
has "colour/49 green"  "$(runc "$(pct 49)")" "$GREEN"
has "colour/50 yellow" "$(runc "$(pct 50)")" "$YELLOW"
has "colour/74 yellow" "$(runc "$(pct 74)")" "$YELLOW"
has "colour/75 orange" "$(runc "$(pct 75)")" "$ORANGE"
has "colour/89 orange" "$(runc "$(pct 89)")" "$ORANGE"
has "colour/90 red"    "$(runc "$(pct 90)")" "$RED"
has "colour/100 red"   "$(runc "$(pct 100)")" "$RED"
hasnot "colour/NO_COLOR clean" "$(run "$(pct 90)")" $'\033'

# 4. graceful degradation
hasnot "degrade/no rate_limits" "$(run "$(pct 40)")" "5h ["
hasnot "degrade/non-git dir"    "$(run "$(pct 40)")" "main"
has    "degrade/dir still shown" "$(run "$(pct 40)")" "$(basename "$PLAIN")"
hasnot "degrade/no ctx field" "$(run '{"workspace":{"current_dir":"'"$PLAIN"'"},"model":{"display_name":"Sonnet 5"}}')" "ctx ["
has    "degrade/model without ctx" "$(run '{"workspace":{"current_dir":"'"$PLAIN"'"},"model":{"display_name":"Sonnet 5"}}')" "Sonnet 5"
run '' >/dev/null 2>&1; eq "degrade/empty stdin exit 0" "$?" "0"
run 'not json at all' >/dev/null 2>&1; eq "degrade/garbage exit 0" "$?" "0"

# 5. reset clock: future shown, past hidden
fut=$(printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}},"workspace":{"current_dir":"%s"}}' $((NOW+5400)) "$PLAIN")
pst=$(printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s}},"workspace":{"current_dir":"%s"}}' $((NOW-60)) "$PLAIN")
has    "reset/future shown" "$(run "$fut")" "⟳"
hasnot "reset/past hidden"  "$(run "$pst")" "⟳"

# 6. git detail: dirty marker and ahead/behind
touch "$REPO/untracked"
has "git/dirty marker" "$(run "$full")" "●"
git -C "$REPO" rm -q --cached untracked 2>/dev/null; rm -f "$REPO/untracked"
hasnot "git/clean has no marker" "$(run "$full")" "●"

# 7. token formatting
has "fmt/200K" "$(run "$(pct 50)")" "100K/200K"

# 8. float percentages from the API must not break arithmetic
has "float/63.7 floors to 63" "$(run '{"context_window":{"used_percentage":63.7,"context_window_size":200000},"workspace":{"current_dir":"'"$PLAIN"'"}}')" "63%"

rm -rf "$REPO" "$PLAIN"
echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
