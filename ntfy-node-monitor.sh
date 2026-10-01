sudo sh <<'EOF'
set -eu

NTFY_URL='https://ntfy./monerod-monitor'
NTFY_TOKEN='*****'

OS="$(uname -s)"

if [ "$OS" = "FreeBSD" ]; then
    pkg install -y curl jq
    PLATFORM="freebsd"
else
    . /etc/os-release
    case "${ID:-}" in
        arch|cachyos|endeavouros|manjaro)
            pacman -Sy --noconfirm --needed curl jq
            ;;
        debian|ubuntu|linuxmint|pop)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq
            ;;
        *)
            echo "Unsupported OS: ${ID:-unknown}"
            exit 1
            ;;
    esac
    PLATFORM="linux"
fi

mkdir -p /var/lib/ntfy-node-monitor
chmod 700 /var/lib/ntfy-node-monitor

cat >/usr/local/sbin/ntfy-node-monitor <<'SCRIPT'
#!/bin/sh

NTFY_URL='https://ntfy.sh/monerod-monitor'
NTFY_TOKEN='***'

MONERO_RPC='http://127.0.0.1:18081'
TOR_SOCKS='127.0.0.1:9050'

CHECK_INTERVAL=300
STALL_SECONDS=900

BANDWIDTH_SAMPLE=60
BANDWIDTH_THRESHOLD_MBPS=500
BANDWIDTH_COOLDOWN=900

HOST="$(hostname -s 2>/dev/null || hostname)"
OS="$(uname -s)"

STATE_DIR='/var/lib/ntfy-node-monitor'
STATE_FILE="$STATE_DIR/health.state"
BW_STATE="$STATE_DIR/bandwidth.state"

mkdir -p "$STATE_DIR"

NOW="$(date +%s)"

PREV_HEIGHT=''
LAST_CHANGE="$NOW"
PREV_STATUS='unknown'

if [ -r "$STATE_FILE" ]; then
    . "$STATE_FILE"
    PREV_HEIGHT="${HEIGHT:-}"
    LAST_CHANGE="${LAST_CHANGE:-$NOW}"
    PREV_STATUS="${STATUS:-unknown}"
fi

FAILURES=''
MONERO_LINES=''
TOR_LINES=''
NETWORK_LINES=''

add_failure() {
    FAILURES="${FAILURES}
- $1"
}

monero_line() {
    MONERO_LINES="${MONERO_LINES}
- $1"
}

tor_line() {
    TOR_LINES="${TOR_LINES}
- $1"
}

network_line() {
    NETWORK_LINES="${NETWORK_LINES}
- $1"
}

notify() {
    TITLE="$1"
    PRIORITY="$2"
    TAGS="$3"
    BODY="$4"

    curl -fsS -o /dev/null \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $TITLE" \
        -H "Priority: $PRIORITY" \
        -H "Tags: $TAGS" \
        -H "Markdown: yes" \
        --data-binary "$BODY" \
        "$NTFY_URL"
}

# =========================================================
# MONEROD PROCESS
# =========================================================

if pgrep -x monerod >/dev/null 2>&1; then
    monero_line "✅ Process: **running**"
else
    monero_line "❌ Process: **not running**"
    add_failure "**monerod is not running**"
fi

# =========================================================
# MONERO RPC
# =========================================================

INFO="$(curl -fsS \
    --connect-timeout 5 \
    --max-time 15 \
    "$MONERO_RPC/get_info" 2>/dev/null || true)"

HEIGHT=''

if printf '%s' "$INFO" | jq -e '.height' >/dev/null 2>&1; then

    HEIGHT="$(printf '%s' "$INFO" | jq -r '.height // 0')"
    TARGET="$(printf '%s' "$INFO" | jq -r '.target_height // 0')"
    INCOMING="$(printf '%s' "$INFO" | jq -r '.incoming_connections_count // 0')"
    OUTGOING="$(printf '%s' "$INFO" | jq -r '.outgoing_connections_count // 0')"
    SYNCED="$(printf '%s' "$INFO" | jq -r '.synchronized // false')"
    OFFLINE="$(printf '%s' "$INFO" | jq -r '.offline // false')"
    NETTYPE="$(printf '%s' "$INFO" | jq -r '.nettype // "unknown"')"

    monero_line "✅ RPC: **responding**"
    monero_line "⛓️ Height: \`$HEIGHT\`"
    monero_line "🌐 Network: \`$NETTYPE\`"
    monero_line "🔗 Peers: **$INCOMING inbound / $OUTGOING outbound**"

    if [ "$SYNCED" = "true" ]; then
        monero_line "✅ Sync: **synchronized**"
    else
        monero_line "⚠️ Sync: **not synchronized**"

        if [ "$TARGET" -gt 0 ] 2>/dev/null; then
            LAG=$((TARGET - HEIGHT))
            [ "$LAG" -lt 0 ] && LAG=0
            monero_line "📉 Target: \`$TARGET\` — **$LAG blocks behind**"
        fi
    fi

    if [ "$OFFLINE" = "true" ]; then
        add_failure "**monerod reports offline mode**"
    fi

    if [ "$OUTGOING" -eq 0 ] 2>/dev/null; then
        add_failure "**monerod has zero outgoing peers**"
    fi

    # Block-height progression

    if [ -z "$PREV_HEIGHT" ]; then
        LAST_CHANGE="$NOW"

    elif [ "$HEIGHT" != "$PREV_HEIGHT" ]; then
        LAST_CHANGE="$NOW"

    else
        AGE=$((NOW - LAST_CHANGE))
        MINUTES=$((AGE / 60))

        if [ "$AGE" -ge "$STALL_SECONDS" ]; then
            monero_line "❌ Height unchanged for **${MINUTES} minutes**"
            add_failure "**block height has not advanced for ${MINUTES} minutes**"
        else
            monero_line "🕒 Height unchanged for ${MINUTES} minutes"
        fi
    fi

else
    monero_line "❌ RPC: **unreachable**"
    add_failure "**Monero RPC is not responding on port 18081**"
fi

# =========================================================
# TOR
# =========================================================

if pgrep -x tor >/dev/null 2>&1; then
    tor_line "✅ Process: **running**"
else
    tor_line "❌ Process: **not running**"
    add_failure "**Tor process is not running**"
fi

TOR_RESULT="$(curl -fsS \
    --connect-timeout 10 \
    --max-time 25 \
    --socks5-hostname "$TOR_SOCKS" \
    https://check.torproject.org/api/ip 2>/dev/null || true)"

if printf '%s' "$TOR_RESULT" | jq -e '.IsTor == true' >/dev/null 2>&1; then

    TOR_IP="$(printf '%s' "$TOR_RESULT" | jq -r '.IP // "unknown"')"

    tor_line "✅ SOCKS: \`$TOR_SOCKS\`"
    tor_line "✅ Internet routing: **working**"
    tor_line "🧅 Exit IP: \`$TOR_IP\`"

else
    tor_line "❌ SOCKS/outbound test: **failed**"
    add_failure "**Tor outbound connectivity failed**"
fi

# =========================================================
# BANDWIDTH
# =========================================================

if [ "$OS" = "FreeBSD" ]; then
    IFACE="$(route -n get default 2>/dev/null |
        awk '/interface:/ {print $2; exit}')"
else
    IFACE="$(ip route show default 2>/dev/null |
        awk 'NR==1 {print $5}')"
fi

read_counters() {

    if [ "$OS" = "FreeBSD" ]; then

        netstat -bI "$IFACE" -n 2>/dev/null |
        awk '
        NR == 1 {
            for (i=1; i<=NF; i++) {
                if ($i == "Ibytes") ib=i
                if ($i == "Obytes") ob=i
            }
            next
        }

        NR > 1 && ib && ob {
            if ($ib ~ /^[0-9]+$/ && $ob ~ /^[0-9]+$/) {
                print $ib, $ob
                exit
            }
        }'

    else

        RXFILE="/sys/class/net/$IFACE/statistics/rx_bytes"
        TXFILE="/sys/class/net/$IFACE/statistics/tx_bytes"

        [ -r "$RXFILE" ] || return 1
        [ -r "$TXFILE" ] || return 1

        printf '%s %s\n' \
            "$(cat "$RXFILE")" \
            "$(cat "$TXFILE")"
    fi
}

if [ -n "$IFACE" ]; then

    COUNTERS1="$(read_counters || true)"

    if [ -n "$COUNTERS1" ]; then

        RX1="$(echo "$COUNTERS1" | awk '{print $1}')"
        TX1="$(echo "$COUNTERS1" | awk '{print $2}')"

        sleep "$BANDWIDTH_SAMPLE"

        COUNTERS2="$(read_counters || true)"

        RX2="$(echo "$COUNTERS2" | awk '{print $1}')"
        TX2="$(echo "$COUNTERS2" | awk '{print $2}')"

        if [ -n "$RX2" ] && [ "$RX2" -ge "$RX1" ] &&
           [ "$TX2" -ge "$TX1" ]; then

            RX_MBPS="$(awk \
                -v a="$RX1" -v b="$RX2" \
                -v s="$BANDWIDTH_SAMPLE" \
                'BEGIN {printf "%.2f", ((b-a)*8)/(s*1000000)}')"

            TX_MBPS="$(awk \
                -v a="$TX1" -v b="$TX2" \
                -v s="$BANDWIDTH_SAMPLE" \
                'BEGIN {printf "%.2f", ((b-a)*8)/(s*1000000)}')"

            network_line "🌐 Interface: \`$IFACE\`"
            network_line "⬇️ RX: **${RX_MBPS} Mbps**"
            network_line "⬆️ TX: **${TX_MBPS} Mbps**"

            HIGH="$(awk \
                -v r="$RX_MBPS" \
                -v t="$TX_MBPS" \
                -v h="$BANDWIDTH_THRESHOLD_MBPS" \
                'BEGIN {print (r >= h || t >= h) ? 1 : 0}')"

            if [ "$HIGH" -eq 1 ]; then

                LAST_BW=0

                [ -r "$BW_STATE" ] &&
                    LAST_BW="$(cat "$BW_STATE" 2>/dev/null || echo 0)"

                if [ $((NOW - LAST_BW)) -ge "$BANDWIDTH_COOLDOWN" ]; then

                    BODY="## 📡 High Bandwidth Alert

**Host:** \`$HOST\`
**Interface:** \`$IFACE\`

### Traffic

⬇️ **RX:** ${RX_MBPS} Mbps  
⬆️ **TX:** ${TX_MBPS} Mbps

**Threshold:** ${BANDWIDTH_THRESHOLD_MBPS} Mbps

### Node status

🟠 Monero height: \`${HEIGHT:-unknown}\`

🧅 Tor: $(printf '%s' "$TOR_RESULT" |
                        jq -r 'if .IsTor == true then "working" else "failed" end' 2>/dev/null || echo unknown)

---
$(date)"

                    if notify \
                        "📡 High bandwidth · $HOST" \
                        "high" \
                        "warning,chart_with_upwards_trend" \
                        "$BODY"; then

                        echo "$NOW" >"$BW_STATE"
                    fi
                fi
            fi
        fi
    fi

else
    network_line "⚠️ Could not determine default interface"
fi

# =========================================================
# OVERALL HEALTH
# =========================================================

if [ -n "$FAILURES" ]; then
    STATUS='failed'
else
    STATUS='healthy'
fi

# =========================================================
# FAILURE ALERT
# =========================================================

if [ "$STATUS" = 'failed' ]; then

    BODY="## 🚨 Node Health Alert

**Host:** \`$HOST\`
**Status:** 🔴 **DEGRADED**
**Time:** $(date)

### 🚨 Problems
$FAILURES

### 🟠 Monero
$MONERO_LINES

### 🧅 Tor
$TOR_LINES

### 📡 Network
$NETWORK_LINES

---
Automatic infrastructure monitor"

    notify \
        "🚨 Node problem · $HOST" \
        "high" \
        "warning,skull" \
        "$BODY"

# =========================================================
# RECOVERY ALERT
# =========================================================

elif [ "$PREV_STATUS" = 'failed' ]; then

    BODY="## ✅ Node Recovered

**Host:** \`$HOST\`
**Status:** 🟢 **HEALTHY**
**Time:** $(date)

### 🟠 Monero
$MONERO_LINES

### 🧅 Tor
$TOR_LINES

### 📡 Network
$NETWORK_LINES

---
All monitored services are healthy again."

    notify \
        "✅ Node recovered · $HOST" \
        "default" \
        "white_check_mark,lock" \
        "$BODY"
fi

# =========================================================
# SAVE STATE
# =========================================================

cat >"$STATE_FILE" <<STATE
HEIGHT='${HEIGHT:-}'
LAST_CHANGE='$LAST_CHANGE'
STATUS='$STATUS'
STATE

chmod 600 "$STATE_FILE"

logger -t ntfy-node-monitor \
    "status=$STATUS height=${HEIGHT:-unknown}"

[ "$STATUS" = "healthy" ] && exit 0
exit 1
SCRIPT

chmod 700 /usr/local/sbin/ntfy-node-monitor

# =========================================================
# LINUX SYSTEMD
# =========================================================

if [ "$PLATFORM" = "linux" ]; then

    # Remove old separate timers if present
    systemctl disable --now \
        ntfy-monero-tor-check.timer \
        ntfy-bandwidth-monitor.timer \
        ntfy-bandwidth-monitor.service \
        2>/dev/null || true

cat >/etc/systemd/system/ntfy-node-monitor.service <<'UNIT'
[Unit]
Description=Monero Tor Bandwidth ntfy Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ntfy-node-monitor
UNIT

cat >/etc/systemd/system/ntfy-node-monitor.timer <<'UNIT'
[Unit]
Description=Run Monero Tor Bandwidth health monitor

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=20s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now ntfy-node-monitor.timer

# =========================================================
# FREEBSD CRON
# =========================================================

else

    (
        crontab -l 2>/dev/null |
            grep -v 'ntfy-monero-tor-check' |
            grep -v 'ntfy-bandwidth-monitor' |
            grep -v 'ntfy-node-monitor' || true

        echo '*/5 * * * * /usr/local/sbin/ntfy-node-monitor >/dev/null 2>&1'
    ) | crontab -

fi

echo
echo "============================================"
echo " Unified ntfy node monitor installed"
echo "============================================"
echo
echo "Checks:"
echo "  Monerod process"
echo "  Monero RPC"
echo "  Block progression"
echo "  Peer connectivity"
echo "  Tor process"
echo "  Tor SOCKS"
echo "  Tor outbound routing"
echo "  Network RX/TX bandwidth"
echo
echo "Health interval:        5 minutes"
echo "Block stall threshold: 15 minutes"
echo "Bandwidth threshold:   500 Mbps"
echo "Bandwidth sample:      60 seconds"
echo "Alert cooldown:        15 minutes"
echo
echo "Running initial check..."
/usr/local/sbin/ntfy-node-monitor || true

echo
echo "Sending installation notification..."

curl -fsS -o /dev/null \
    -H "Authorization: Bearer $NTFY_TOKEN" \
    -H "Title: ✅ Node monitor installed · $(hostname -s 2>/dev/null || hostname)" \
    -H "Priority: low" \
    -H "Tags: white_check_mark,lock" \
    -H "Markdown: yes" \
    --data-binary "## 🟠 Monero Node Monitoring Active

**Host:** \`$(hostname -s 2>/dev/null || hostname)\`

✅ Monerod process  
✅ RPC health  
✅ Block-height progression  
✅ Peer connectivity  
✅ Tor process  
✅ Tor SOCKS  
✅ Tor internet routing  
✅ Bandwidth monitoring  
✅ Failure alerts  
✅ Recovery notifications

**Bandwidth alert:** 500 Mbps  
**Stalled chain alert:** 15 minutes  
**Health checks:** every 5 minutes" \
    "$NTFY_URL"

echo
echo "Installation complete."
EOF
