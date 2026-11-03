#!/usr/bin/env bash
# Count how many times each plant was triggered, from the service journal.
#
# mami_sound prints one status line a second, ending in touch=XY: X is A
# while plant A is touched, Y is B while plant B is touched, '-' otherwise.
# A hold is one trigger however long it lasts. A release of GAP seconds or
# less followed by another touch (a flicker, a hand tapping) folds into the
# same trigger; "raw" counts every edge. Lines come once a second, so a
# touch that starts and ends between two lines is missed.
#
# Usage:
#   ./trigger-count.sh                            # today, gap 60 s (one visit)
#   ./trigger-count.sh -g 0                       # every edge its own trigger
#   ./trigger-count.sh -s yesterday -u today
#   ./trigger-count.sh -s "2026-11-03 09:00"
#   ./trigger-count.sh -f service-log4.txt        # a saved log instead
set -euo pipefail

unit=mami-sound
since=today
until=
gap=60
file=

usage() { sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts "s:u:g:f:n:h" opt; do
    case $opt in
        s) since=$OPTARG ;;
        u) until=$OPTARG ;;
        g) gap=$OPTARG ;;
        f) file=$OPTARG ;;
        n) unit=$OPTARG ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done

if [[ -n $file ]]; then
    title=$file
    read_log() { cat -- "$file"; }
else
    title="$unit since $since${until:+ until $until}"
    read_log() {
        journalctl -u "$unit" --since "$since" ${until:+--until "$until"} \
            -o short-iso --no-pager
    }
fi

read_log | awk -v gap="$gap" -v title="$title" '
function clock(t,  p) { split(t, p, ":"); return p[1] * 3600 + p[2] * 60 + p[3] }
function dur(s,  h, m) {
    h = int(s / 3600); m = int(s % 3600 / 60); s = s % 60
    if (h) return sprintf("%dh%02dm%02ds", h, m, s)
    if (m) return sprintf("%dm%02ds", m, s)
    return sprintf("%ds", s)
}
BEGIN { name[1] = "A"; name[2] = "B" }
{
    pid = ""; touch = ""
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^mami_sound\[/) pid = $i
        else if ($i ~ /^touch=/) touch = substr($i, 7, 2)
    }
    if (pid == "" || length(touch) != 2) next

    # short-iso: 2026-11-03T10:00:00+0700   classic: Nov 03 10:00:00
    if ($1 ~ /^[0-9][0-9][0-9][0-9]-/) { day = substr($1, 1, 10); hms = substr($1, 12, 8) }
    else { day = $1 " " $2; hms = $3 }
    # Seconds since the first line; assume each new date is the next day.
    if (day != last_day) { if (last_day != "") base += 86400; last_day = day }
    now = base + clock(hms)
    hour = substr(hms, 1, 2)

    lines++
    if (first == "") first = day " " hms
    last = day " " hms

    # A new process starts untouched, so its first touch is a fresh edge.
    if (pid != last_pid) {
        if (last_pid != "") restarts++
        on[1] = on[2] = 0
        last_pid = pid
    }

    for (p = 1; p <= 2; p++) {
        if (substr(touch, p, 1) != name[p]) { on[p] = 0; continue }
        if (!on[p]) {
            raw[p]++
            # A 1 s step between touched lines means no release at all.
            if (!(p in seen) || now - seen[p] - 1 > gap) {
                trig[p]++
                hours[hour] = 1
                per[p, hour]++
                start[p] = now
            }
        }
        on[p] = 1
        seen[p] = now
        touched[p]++
        held = now - start[p] + 1
        if (held > longest[p]) longest[p] = held
    }
}
END {
    print "mami-sound triggers -- " title
    if (!lines) { print "no status lines found (service not running, or wrong window?)"; exit }
    printf "log span  %s -> %s  (%d status lines, ~%s running, %d restarts)\n", \
        first, last, lines, dur(lines), restarts
    printf "a re-touch within %ss of release counts as the same trigger\n\n", gap
    printf "%-6s%9s%6s%12s%10s\n", "plant", "triggers", "raw", "touched", "longest"
    for (p = 1; p <= 2; p++)
        printf "%-6s%9d%6d%12s%10s\n", name[p], trig[p], raw[p], dur(touched[p]), dur(longest[p])

    n = 0
    for (h = 0; h < 24; h++) { k = sprintf("%02d", h); if (k in hours) n++ }
    if (!n) exit
    printf "\nper hour     A     B\n"
    for (h = 0; h < 24; h++) {
        k = sprintf("%02d", h)
        if (k in hours) printf "%s:00     %4d  %4d\n", k, per[1, k], per[2, k]
    }
}'
