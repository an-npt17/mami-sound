#!/usr/bin/env bash
# Send each hour's plant triggers to a Telegram chat.
#
# Just after every full hour it runs trigger-count.sh over the hour that
# ended (10:00 -> 11:00, say) and posts the A and B trigger counts, so the
# chat holds one line per box per hour. Counting is trigger-count.sh's: a
# re-touch within GAP seconds of release is the same trigger. Each hour is
# counted on its own, so a hold that spans the hour mark counts in both.
#
# Settings come from the environment (mami-telegram.service sets them):
#   MAMI_BOX_NAME        name shown in each message, e.g. "Box 1"
#   MAMI_PLANT_A_SOUND   what plant A plays, e.g. "tiếng chim" (optional)
#   MAMI_PLANT_B_SOUND   what plant B plays, e.g. "tiếng chuông" (optional)
#   TELEGRAM_BOT_TOKEN   from @BotFather          (keep out of git)
#   TELEGRAM_CHAT_ID     chat or group to post to (keep out of git)
#   MAMI_GAP             re-touch gap in seconds, default 60
#
# Usage:
#   ./telegram-report.sh          # run forever, one message per hour
#   ./telegram-report.sh -1       # send the last full hour now, then exit
#   ./telegram-report.sh -n       # print the last full hour, send nothing
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
box=${MAMI_BOX_NAME:-$(hostname)}
gap=${MAMI_GAP:-60}
sound_a=${MAMI_PLANT_A_SOUND:-}
sound_b=${MAMI_PLANT_B_SOUND:-}
mode=loop

usage() { sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts "1nh" opt; do
    case $opt in
        1) mode=once ;;
        n) mode=dry ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done

if [[ $mode != dry && ( -z ${TELEGRAM_BOT_TOKEN:-} || -z ${TELEGRAM_CHAT_ID:-} ) ]]; then
    echo "TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set" >&2
    exit 1
fi

# Local-time start of the current hour, as epoch seconds.
hour_top() { date -d "$(date '+%F %H:00')" +%s; }

# Message for the hour starting at epoch $1.
report() {
    local from to out a b
    from=$(date -d "@$1" '+%F %H:%M:%S')
    to=$(date -d "@$(($1 + 3600))" '+%F %H:%M:%S')
    out=$("$here/trigger-count.sh" -s "$from" -u "$to" -g "$gap" 2>&1) || true
    # The summary table rows: "A  <triggers> <raw> <touched> <longest>".
    a=$(awk '$1 == "A" && NF == 5 { print $2 }' <<<"$out")
    b=$(awk '$1 == "B" && NF == 5 { print $2 }' <<<"$out")
    printf '%s  %s-%s\n' "$box" "$(date -d "@$1" '+%a %d %b %H:00')" \
        "$(date -d "@$(($1 + 3600))" '+%H:00')"
    if [[ -z $a ]]; then
        printf 'no status lines -- sound service not running?\n'
    else
        printf 'Plant A%s: %s touches\nPlant B%s: %s touches\n' \
            "${sound_a:+ ($sound_a)}" "$a" "${sound_b:+ ($sound_b)}" "$b"
    fi
}

send() {
    curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$1"
}

# Send, retrying a few times: the museum network drops now and then, and an
# hour lost to one bad minute is a gap in the record.
deliver() {
    local msg=$1 code try
    for try in 1 2 3 4 5; do
        code=$(send "$msg" 2>/dev/null) || code=000
        if [[ $code == 200 ]]; then echo "sent: ${msg//$'\n'/ | }"; return 0; fi
        echo "send failed (http $code), try $try" >&2
        sleep 60
    done
    return 1
}

case $mode in
    dry)  report $(($(hour_top) - 3600)); exit ;;
    once) deliver "$(report $(($(hour_top) - 3600)))"; exit ;;
esac

echo "reporting $box hourly to chat $TELEGRAM_CHAT_ID"
while true; do
    next=$(($(hour_top) + 3600))
    # 10 s past the hour so the last status line of the hour is in the journal.
    sleep $((next + 10 - $(date +%s)))
    deliver "$(report $((next - 3600)))" || echo "gave up on hour $(date -d "@$((next - 3600))" '+%F %H:00')" >&2
done
