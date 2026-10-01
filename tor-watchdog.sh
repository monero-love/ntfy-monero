sudo sh <<'EOF'
cat >/usr/local/sbin/tor-watchdog <<'WATCHDOG'
#!/bin/sh

SOCKS_HOST="127.0.0.1"
SOCKS_PORT="9050"

CHECK_INTERVAL=60
FAIL_LIMIT=3

STATE_DIR="/var/lib/tor-watchdog"
FAIL_FILE="$STATE_DIR/failures"
DOWN_FILE="$STATE_DIR/down"

LOG_FILE="/var/log/supervisor/tor-watchdog.log"

NTFY_CONF="/usr/local/etc/tor-watchdog-ntfy.conf"

mkdir -p "$STATE_DIR"

timestamp()
{
    date '+%Y-%m-%d %H:%M:%S'
}

log()
{
    printf '%s  %-9s  %s\n' "$(timestamp)" "$1" "$2" >> "$LOG_FILE"
}

# ------------------------------------------------------------
# ntfy config
#
# Example:
#
# NTFY_URL="https://ntfy.example.com/tor-alerts"
# NTFY_TOKEN="tk_xxxxxxxxx"
# ------------------------------------------------------------
if [ -f "$NTFY_CONF" ]; then
    . "$NTFY_CONF"
fi

NTFY_URL="${NTFY_URL:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"

hostname_short()
{
    hostname 2>/dev/null | cut -d. -f1
}

notify()
{
    TITLE="$1"
    MESSAGE="$2"
    PRIORITY="${3:-default}"
    TAGS="${4:-tor}"

    [ -n "$NTFY_URL" ] || return 0

    HOST="$(hostname_short)"

    if [ -n "$NTFY_TOKEN" ]; then
        curl \
            --silent \
            --show-error \
            --fail \
            --max-time 15 \
            -H "Authorization: Bearer $NTFY_TOKEN" \
            -H "Title: $TITLE" \
            -H "Priority: $PRIORITY" \
            -H "Tags: $TAGS" \
            -d "Host: $HOST
$MESSAGE" \
            "$NTFY_URL" \
            >/dev/null 2>&1 || \
            log "NTFY" "Failed to send notification"
    else
        curl \
            --silent \
            --show-error \
            --fail \
            --max-time 15 \
            -H "Title: $TITLE" \
            -H "Priority: $PRIORITY" \
            -H "Tags: $TAGS" \
            -d "Host: $HOST
$MESSAGE" \
            "$NTFY_URL" \
            >/dev/null 2>&1 || \
            log "NTFY" "Failed to send notification"
    fi
}

get_failures()
{
    if [ -f "$FAIL_FILE" ]; then
        cat "$FAIL_FILE" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

set_failures()
{
    echo "$1" > "$FAIL_FILE"
}

check_tor()
{
    RESPONSE="$(
        curl \
            --silent \
            --show-error \
            --fail \
            --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" \
            --connect-timeout 10 \
            --max-time 20 \
            https://check.torproject.org/api/ip \
            2>/dev/null
    )" || return 1

    echo "$RESPONSE" |
        grep -Eq '"IsTor"[[:space:]]*:[[:space:]]*true' ||
        return 1

    IP="$(
        echo "$RESPONSE" |
        sed -n 's/.*"IP"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
    )"

    log "HEALTHY" "Tor online | SOCKS ${SOCKS_HOST}:${SOCKS_PORT} | exit ${IP:-unknown}"

    if [ -f "$DOWN_FILE" ]; then
        rm -f "$DOWN_FILE"

        log "RECOVERED" "Tor connectivity restored | exit ${IP:-unknown}"

        notify \
            "Tor recovered" \
            "Tor connectivity has been restored.
SOCKS: ${SOCKS_HOST}:${SOCKS_PORT}
Exit IP: ${IP:-unknown}" \
            "default" \
            "white_check_mark,tor"
    fi

    return 0
}

restart_tor()
{
    log "RESTART" "Tor unhealthy after ${FAIL_LIMIT} consecutive failures"

    touch "$DOWN_FILE"

    notify \
        "Tor unhealthy" \
        "Tor failed ${FAIL_LIMIT} consecutive health checks.
Restarting Tor through Supervisor." \
        "high" \
        "warning,tor"

    log "ACTION" "Requesting restart through Supervisor"

    if supervisorctl restart tor >> "$LOG_FILE" 2>&1; then

        sleep 15

        log "OK" "Supervisor restart completed"

        notify \
            "Tor restarted" \
            "Supervisor successfully restarted the Tor process.
Waiting for the next health check to confirm recovery." \
            "default" \
            "arrows_counterclockwise,tor"

    else

        log "ERROR" "Supervisor failed to restart Tor"

        notify \
            "Tor restart failed" \
            "Supervisor was unable to restart Tor.
Manual intervention may be required." \
            "urgent" \
            "rotating_light,tor"

        return 1
    fi
}

log "START" "Tor watchdog started"

notify \
    "Tor watchdog started" \
    "Tor watchdog is active.
SOCKS: ${SOCKS_HOST}:${SOCKS_PORT}
Failure threshold: ${FAIL_LIMIT}
Check interval: ${CHECK_INTERVAL}s" \
    "min" \
    "information_source,tor"

while :; do

    if check_tor; then

        set_failures 0

    else

        FAILURES="$(get_failures)"

        case "$FAILURES" in
            ''|*[!0-9]*)
                FAILURES=0
                ;;
        esac

        FAILURES=$((FAILURES + 1))
        set_failures "$FAILURES"

        log "WARNING" "Tor connectivity failed | attempt ${FAILURES}/${FAIL_LIMIT}"

        if [ "$FAILURES" -ge "$FAIL_LIMIT" ]; then
            restart_tor || true
            set_failures 0
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
WATCHDOG

chmod 755 /usr/local/sbin/tor-watchdog

cat >/usr/local/etc/tor-watchdog-ntfy.conf <<'NTFY'
NTFY_URL="https://ntfy.example.com/tor-alerts"
NTFY_TOKEN=""
NTFY

chmod 600 /usr/local/etc/tor-watchdog-ntfy.conf

supervisorctl restart tor-watchdog

echo
echo "ntfy support added."
echo
echo "Edit:"
echo "  sudo vi /usr/local/etc/tor-watchdog-ntfy.conf"
echo
echo "Then test:"
echo "  sudo supervisorctl restart tor-watchdog"
echo "  sudo tail -f /var/log/supervisor/tor-watchdog.log"
EOF
