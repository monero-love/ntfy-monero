sudo bash <<'EOF'
set -euo pipefail

NTFY_URL='https://ntfy.sh/ntfy-monerod'
NTFY_TOKEN='tk_'

MONITOR_USER='user'
MONERO_CONTAINER='monerod'
P2POOL_CONTAINER='p2pool-mini'

UID_NUM="$(id -u "$MONITOR_USER")"
DOCKER_SOCKET="/run/user/${UID_NUM}/docker.sock"

echo "=========================================="
echo " Installing unified node monitor"
echo "=========================================="

# ---------------------------------------------------------
# Packages
# ---------------------------------------------------------

if command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed curl jq smartmontools
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl jq smartmontools
else
    echo "Unsupported Linux distribution."
    exit 1
fi

# ---------------------------------------------------------
# Remove obsolete monitors
# ---------------------------------------------------------

echo
echo "Removing old ntfy monitors..."

OLD_UNITS="
ntfy-monero-tor-check.timer
ntfy-monero-tor-check.service
ntfy-node-monitor.timer
ntfy-node-monitor.service
ntfy-docker-monero-tor.timer
ntfy-docker-monero-tor.service
ntfy-bandwidth-monitor.timer
ntfy-bandwidth-monitor.service
"

for unit in $OLD_UNITS; do
    systemctl disable --now "$unit" 2>/dev/null || true
    rm -f "/etc/systemd/system/$unit"
done

# Root cron cleanup
TMP="$(mktemp)"
crontab -l 2>/dev/null |
    grep -vE 'ntfy-(monero|node|docker|bandwidth)' \
    >"$TMP" || true
crontab "$TMP" 2>/dev/null || true
rm -f "$TMP"

# baz cron cleanup
TMP="$(mktemp)"
sudo -u "$MONITOR_USER" crontab -l 2>/dev/null |
    grep -vE 'ntfy-(monero|node|docker|bandwidth)' \
    >"$TMP" || true
sudo -u "$MONITOR_USER" crontab "$TMP" 2>/dev/null || true
rm -f "$TMP"

# ---------------------------------------------------------
# State
# ---------------------------------------------------------

install -d \
    -o "$MONITOR_USER" \
    -g "$MONITOR_USER" \
    -m 700 \
    /var/lib/ntfy-monero-monitor

# ---------------------------------------------------------
# Main monitor
# ---------------------------------------------------------

cat >/usr/local/sbin/ntfy-monero-monitor <<'SCRIPT'
#!/usr/bin/env bash
set -u

NTFY_URL='https://ntfy.sh/ntfy-monero'
NTFY_TOKEN='tk_'

MONERO_CONTAINER='monerod'
P2POOL_CONTAINER='p2pool-mini'

MONERO_RPC_PORT=18089

STALL_SECONDS=900

BANDWIDTH_THRESHOLD_MBPS=500
BANDWIDTH_SAMPLE_SECONDS=60
BANDWIDTH_COOLDOWN_SECONDS=900

HOST="$(hostname -s)"
NOW="$(date +%s)"

STATE_DIR='/var/lib/ntfy-monero-monitor'
HEALTH_STATE="$STATE_DIR/health.state"
BW_STATE="$STATE_DIR/bandwidth.state"

PREV_HEIGHT=''
LAST_HEIGHT_CHANGE="$NOW"
PREV_STATUS='unknown'

if [[ -r "$HEALTH_STATE" ]]; then
    source "$HEALTH_STATE"
    PREV_HEIGHT="${HEIGHT:-}"
    LAST_HEIGHT_CHANGE="${LAST_HEIGHT_CHANGE:-$NOW}"
    PREV_STATUS="${STATUS:-unknown}"
fi

FAILURES=''
MONERO=''
P2POOL=''
NETWORK=''

failure() {
    FAILURES+=$'\n- '"$1"
}

monero() {
    MONERO+=$'\n- '"$1"
}

p2pool() {
    P2POOL+=$'\n- '"$1"
}

network() {
    NETWORK+=$'\n- '"$1"
}

notify() {
    local title="$1"
    local priority="$2"
    local tags="$3"
    local body="$4"

    curl -fsS -o /dev/null \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tags" \
        -H "Markdown: yes" \
        --data-binary "$body" \
        "$NTFY_URL"
}

# =========================================================
# MONEROD CONTAINER
# =========================================================

MONERO_RUNNING="$(
    docker inspect \
        -f '{{.State.Running}}' \
        "$MONERO_CONTAINER" 2>/dev/null ||
    echo false
)"

MONERO_HEALTH="$(
    docker inspect \
        -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$MONERO_CONTAINER" 2>/dev/null ||
    echo missing
)"

if [[ "$MONERO_RUNNING" == "true" ]]; then
    monero "🐳 Container: **running**"
else
    monero "❌ Container: **stopped / missing**"
    failure "**monerod container is not running**"
fi

case "$MONERO_HEALTH" in
    healthy)
        monero "🩺 Docker health: **healthy**"
        ;;
    unhealthy)
        monero "🩺 Docker health: **unhealthy**"
        failure "**monerod Docker health check is failing**"
        ;;
    starting)
        monero "🩺 Docker health: **starting**"
        ;;
    *)
        monero "🩺 Docker health: **$MONERO_HEALTH**"
        ;;
esac

# =========================================================
# MONEROD RPC INSIDE CONTAINER
# =========================================================

INFO=''

if [[ "$MONERO_RUNNING" == "true" ]]; then
    INFO="$(
        docker exec "$MONERO_CONTAINER" sh -c \
        "wget -qO- http://127.0.0.1:${MONERO_RPC_PORT}/get_info 2>/dev/null ||
         curl -fsS http://127.0.0.1:${MONERO_RPC_PORT}/get_info 2>/dev/null ||
         true" \
        2>/dev/null || true
    )"
fi

HEIGHT=''

if [[ -n "$INFO" ]] &&
   printf '%s' "$INFO" | jq -e '.height' >/dev/null 2>&1; then

    HEIGHT="$(printf '%s' "$INFO" | jq -r '.height // 0')"
    SYNCED="$(printf '%s' "$INFO" | jq -r '.synchronized // false')"
    OFFLINE="$(printf '%s' "$INFO" | jq -r '.offline // false')"
    BUSY="$(printf '%s' "$INFO" | jq -r '.busy_syncing // false')"
    POOL="$(printf '%s' "$INFO" | jq -r '.tx_pool_size // 0')"
    NETTYPE="$(printf '%s' "$INFO" | jq -r '.nettype // "unknown"')"
    UPDATE="$(printf '%s' "$INFO" | jq -r '.update_available // false')"

    monero "✅ RPC: **responding**"
    monero "⛓️ Height: \`$HEIGHT\`"
    monero "🌐 Network: \`$NETTYPE\`"
    monero "📦 Tx pool: **$POOL transactions**"

    if [[ "$SYNCED" == "true" ]]; then
        monero "✅ Sync: **synchronized**"
    else
        monero "⚠️ Sync: **not synchronized**"
    fi

    if [[ "$OFFLINE" == "true" ]]; then
        monero "❌ Offline mode: **yes**"
        failure "**monerod reports offline mode**"
    fi

    if [[ "$BUSY" == "true" ]]; then
        monero "🔄 Sync activity: **busy syncing**"
    fi

    if [[ "$UPDATE" == "true" ]]; then
        monero "⬆️ Monero update: **available**"
    fi

    # Block progression
    if [[ -z "$PREV_HEIGHT" ]]; then

        LAST_HEIGHT_CHANGE="$NOW"
        monero "🟢 Chain progress: **baseline established**"

    elif [[ "$HEIGHT" != "$PREV_HEIGHT" ]]; then

        LAST_HEIGHT_CHANGE="$NOW"
        DELTA=$((HEIGHT - PREV_HEIGHT))

        if (( DELTA > 0 )); then
            monero "🟢 Chain progress: **+$DELTA blocks**"
        else
            monero "🟢 Chain progress: **advancing**"
        fi

    else

        AGE=$((NOW - LAST_HEIGHT_CHANGE))
        MINUTES=$((AGE / 60))

        if (( AGE >= STALL_SECONDS )); then
            monero "🔴 Chain progress: **stalled ${MINUTES} minutes**"
            failure "**Monero block height has not advanced for ${MINUTES} minutes**"
        else
            monero "🕒 Same height for **${MINUTES} minutes**"
        fi
    fi

else
    monero "❌ RPC: **unreachable inside container**"
    failure "**monerod RPC is not responding inside the container on port ${MONERO_RPC_PORT}**"
fi

# =========================================================
# P2POOL
# =========================================================

P2_RUNNING="$(
    docker inspect \
        -f '{{.State.Running}}' \
        "$P2POOL_CONTAINER" 2>/dev/null ||
    echo false
)"

P2_HEALTH="$(
    docker inspect \
        -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$P2POOL_CONTAINER" 2>/dev/null ||
    echo missing
)"

if [[ "$P2_RUNNING" == "true" ]]; then
    p2pool "🐳 Container: **running**"
else
    p2pool "❌ Container: **stopped / missing**"
    failure "**p2pool-mini container is not running**"
fi

case "$P2_HEALTH" in
    healthy)
        p2pool "🩺 Docker health: **healthy**"
        ;;
    unhealthy)
        p2pool "🩺 Docker health: **unhealthy**"
        failure "**p2pool-mini Docker health check is failing**"
        ;;
    starting)
        p2pool "🩺 Docker health: **starting**"
        ;;
    *)
        p2pool "🩺 Docker health: **$P2_HEALTH**"
        ;;
esac

# =========================================================
# BANDWIDTH
# =========================================================

IFACE="$(
    ip route show default 2>/dev/null |
    awk 'NR==1 {print $5}'
)"

if [[ -n "$IFACE" ]] &&
   [[ -r "/sys/class/net/$IFACE/statistics/rx_bytes" ]]; then

    RX1="$(cat "/sys/class/net/$IFACE/statistics/rx_bytes")"
    TX1="$(cat "/sys/class/net/$IFACE/statistics/tx_bytes")"

    sleep "$BANDWIDTH_SAMPLE_SECONDS"

    RX2="$(cat "/sys/class/net/$IFACE/statistics/rx_bytes")"
    TX2="$(cat "/sys/class/net/$IFACE/statistics/tx_bytes")"

    if (( RX2 >= RX1 && TX2 >= TX1 )); then

        RX_MBPS="$(
            awk \
                -v a="$RX1" \
                -v b="$RX2" \
                -v s="$BANDWIDTH_SAMPLE_SECONDS" \
                'BEGIN {printf "%.2f", ((b-a)*8)/(s*1000000)}'
        )"

        TX_MBPS="$(
            awk \
                -v a="$TX1" \
                -v b="$TX2" \
                -v s="$BANDWIDTH_SAMPLE_SECONDS" \
                'BEGIN {printf "%.2f", ((b-a)*8)/(s*1000000)}'
        )"

        network "🌐 Interface: \`$IFACE\`"
        network "⬇️ RX: **${RX_MBPS} Mbps**"
        network "⬆️ TX: **${TX_MBPS} Mbps**"

        HIGH="$(
            awk \
                -v rx="$RX_MBPS" \
                -v tx="$TX_MBPS" \
                -v threshold="$BANDWIDTH_THRESHOLD_MBPS" \
                'BEGIN {
                    print (rx >= threshold || tx >= threshold) ? 1 : 0
                }'
        )"

        if [[ "$HIGH" -eq 1 ]]; then

            LAST_BW=0

            if [[ -r "$BW_STATE" ]]; then
                LAST_BW="$(cat "$BW_STATE" 2>/dev/null || echo 0)"
            fi

            if (( NOW - LAST_BW >= BANDWIDTH_COOLDOWN_SECONDS )); then

                BW_BODY="## 📡 High Bandwidth Alert

**Host:** \`$HOST\`
**Interface:** \`$IFACE\`

### Traffic

⬇️ **RX:** ${RX_MBPS} Mbps  
⬆️ **TX:** ${TX_MBPS} Mbps

**Alert threshold:** ${BANDWIDTH_THRESHOLD_MBPS} Mbps  
**Sample:** ${BANDWIDTH_SAMPLE_SECONDS} seconds

### Monero

⛓️ Height: \`${HEIGHT:-unknown}\`

---
$(date)"

                if notify \
                    "📡 High bandwidth · $HOST" \
                    high \
                    "warning,chart_with_upwards_trend" \
                    "$BW_BODY"
                then
                    echo "$NOW" >"$BW_STATE"
                fi
            fi
        fi
    fi
else
    network "⚠️ Default network interface could not be monitored"
fi

# =========================================================
# OVERALL HEALTH
# =========================================================

if [[ -n "$FAILURES" ]]; then
    STATUS='failed'
else
    STATUS='healthy'
fi

# Only alert when transitioning into failure.
if [[ "$STATUS" == "failed" && "$PREV_STATUS" != "failed" ]]; then

    BODY="## 🚨 Monero Node Alert

**Host:** \`$HOST\`  
**Status:** 🔴 **DEGRADED**  
**Time:** $(date)

### 🚨 Problems
$FAILURES

### 🟠 monerod
$MONERO

### ⛏️ p2pool-mini
$P2POOL

### 📡 Network
$NETWORK

---
Automatic Docker node health monitor"

    notify \
        "🚨 Monero node problem · $HOST" \
        high \
        "warning,whale" \
        "$BODY"

# Recovery
elif [[ "$STATUS" == "healthy" && "$PREV_STATUS" == "failed" ]]; then

    BODY="## ✅ Monero Node Recovered

**Host:** \`$HOST\`  
**Status:** 🟢 **HEALTHY**  
**Time:** $(date)

### 🟠 monerod
$MONERO

### ⛏️ p2pool-mini
$P2POOL

### 📡 Network
$NETWORK

---
All monitored services are healthy again."

    notify \
        "✅ Monero node recovered · $HOST" \
        default \
        "white_check_mark,whale" \
        "$BODY"
fi

cat >"$HEALTH_STATE" <<STATE
HEIGHT='${HEIGHT:-}'
LAST_HEIGHT_CHANGE='$LAST_HEIGHT_CHANGE'
STATUS='$STATUS'
STATE

chmod 600 "$HEALTH_STATE"

logger -t ntfy-monero-monitor \
    "status=$STATUS height=${HEIGHT:-unknown}"

# Monitoring problems should not make systemd mark this
# successful monitoring run as a failed unit.
exit 0
SCRIPT

chown root:"$MONITOR_USER" /usr/local/sbin/ntfy-monero-monitor
chmod 750 /usr/local/sbin/ntfy-monero-monitor

# ---------------------------------------------------------
# systemd health monitor
# ---------------------------------------------------------

cat >/etc/systemd/system/ntfy-monero-monitor.service <<UNIT
[Unit]
Description=Rootless Docker Monero and p2pool ntfy monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$MONITOR_USER
Group=$MONITOR_USER

Environment=HOME=/home/$MONITOR_USER
Environment=XDG_RUNTIME_DIR=/run/user/$UID_NUM
Environment=DOCKER_HOST=unix://$DOCKER_SOCKET

ExecStart=/usr/local/sbin/ntfy-monero-monitor
UNIT

cat >/etc/systemd/system/ntfy-monero-monitor.timer <<'UNIT'
[Unit]
Description=Run Monero node health monitor every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=20s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# ---------------------------------------------------------
# SMART → ntfy
# ---------------------------------------------------------

cat >/usr/local/sbin/ntfy-smartd <<'SCRIPT'
#!/bin/sh

NTFY_URL='https://ntfy.bastion.tel/infra-warning'
NTFY_TOKEN='tk_dr676z1g1z02nl9ldnua2vww8d8yl'

HOST="$(hostname -s 2>/dev/null || hostname)"

DEVICE="${SMARTD_DEVICE:-unknown}"
DEVTYPE="${SMARTD_DEVICETYPE:-unknown}"
MESSAGE="${SMARTD_MESSAGE:-SMART warning detected}"
FULL="${SMARTD_FULLMESSAGE:-$MESSAGE}"

case "$MESSAGE" in
    *FAILED*|*FAIL*|*failed*|*failure*|\
    *uncorrectable*|*UNCORRECTABLE*|\
    *critical*|*CRITICAL*)
        PRIORITY='urgent'
        STATUS='🔴 CRITICAL'
        TAGS='rotating_light,warning,computer_disk'
        ;;
    *)
        PRIORITY='high'
        STATUS='🟠 WARNING'
        TAGS='warning,computer_disk'
        ;;
esac

BODY="## 💽 SMART Disk Alert

**Host:** \`$HOST\`  
**Device:** \`$DEVICE\`  
**Device type:** \`$DEVTYPE\`  
**Status:** $STATUS  
**Time:** $(date)

### SMART event

**$MESSAGE**

### Details

\`\`\`
$FULL
\`\`\`

---
smartd disk-health monitor"

curl -fsS -o /dev/null \
    -H "Authorization: Bearer $NTFY_TOKEN" \
    -H "Title: 💽 SMART alert · $HOST · $DEVICE" \
    -H "Priority: $PRIORITY" \
    -H "Tags: $TAGS" \
    -H "Markdown: yes" \
    --data-binary "$BODY" \
    "$NTFY_URL"

logger -t ntfy-smartd \
    "SMART event device=$DEVICE message=$MESSAGE"
SCRIPT

chmod 700 /usr/local/sbin/ntfy-smartd

cat >/etc/smartd.conf <<'SMART'
DEVICESCAN -a -o on -S on -n standby,q -m <nomailer> -M exec /usr/local/sbin/ntfy-smartd
SMART

systemctl enable smartd >/dev/null 2>&1 || true
systemctl restart smartd || {
    echo
    echo "WARNING: smartd failed to start."
    echo "Check with:"
    echo "  sudo smartd -q onecheck -c /etc/smartd.conf"
}

# ---------------------------------------------------------
# Activate
# ---------------------------------------------------------

systemctl daemon-reload
systemctl reset-failed

systemctl enable --now ntfy-monero-monitor.timer
systemctl restart ntfy-monero-monitor.timer

echo
echo "=========================================="
echo " Rootless Docker visibility"
echo "=========================================="

sudo -u "$MONITOR_USER" env \
    HOME="/home/$MONITOR_USER" \
    XDG_RUNTIME_DIR="/run/user/$UID_NUM" \
    DOCKER_HOST="unix://$DOCKER_SOCKET" \
    docker ps \
    --format 'table {{.Names}}\t{{.Status}}'

echo
echo "=========================================="
echo " Running initial node health check"
echo "=========================================="

systemctl start ntfy-monero-monitor.service

journalctl \
    -u ntfy-monero-monitor.service \
    -n 10 \
    --no-pager

echo
echo "=========================================="
echo " SMART devices"
echo "=========================================="

smartctl --scan || true

echo
echo "=========================================="
echo " Sending SMART test"
echo "=========================================="

SMARTD_DEVICE='/dev/test' \
SMARTD_DEVICETYPE='test' \
SMARTD_MESSAGE='SMART monitoring installed successfully' \
SMARTD_FULLMESSAGE='The SMART to ntfy integration is working correctly.' \
/usr/local/sbin/ntfy-smartd

echo
echo "=========================================="
echo " Installation complete"
echo "=========================================="
echo
echo "Active node timer:"
systemctl list-timers \
    ntfy-monero-monitor.timer \
    --no-pager

echo
echo "Old monitor check:"
systemctl list-timers --all --no-pager |
    grep -Ei 'ntfy.*(monero|tor|node|docker)' || true
EOF
