sudo sh <<'EOF'
set -eu

MAIN='/usr/local/sbin/ntfy-node-monitor'

[ -r "$MAIN" ] || {
    echo "Existing ntfy-node-monitor not found."
    exit 1
}

NTFY_URL="$(sed -n "s/^NTFY_URL='\(.*\)'/\1/p" "$MAIN" | head -1)"
NTFY_TOKEN="$(sed -n "s/^NTFY_TOKEN='\(.*\)'/\1/p" "$MAIN" | head -1)"

[ -n "$NTFY_URL" ] || { echo "Could not read NTFY_URL"; exit 1; }
[ -n "$NTFY_TOKEN" ] || { echo "Could not read NTFY_TOKEN"; exit 1; }

OS="$(uname -s)"

if [ "$OS" = "FreeBSD" ]; then
    pkg install -y smartmontools curl
    SMARTCONF='/usr/local/etc/smartd.conf'
else
    . /etc/os-release

    case "${ID:-}" in
        arch|cachyos|endeavouros|manjaro)
            pacman -Sy --noconfirm --needed smartmontools curl
            ;;
        debian|ubuntu|linuxmint|pop)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y smartmontools curl
            ;;
        *)
            echo "Unsupported Linux distribution: ${ID:-unknown}"
            exit 1
            ;;
    esac

    SMARTCONF='/etc/smartd.conf'
fi

cat >/usr/local/sbin/ntfy-smartd <<SCRIPT
#!/bin/sh

NTFY_URL='$NTFY_URL'
NTFY_TOKEN='$NTFY_TOKEN'

HOST="\$(hostname -s 2>/dev/null || hostname)"
DEVICE="\${SMARTD_DEVICE:-unknown}"
DEVTYPE="\${SMARTD_DEVICETYPE:-unknown}"
MESSAGE="\${SMARTD_MESSAGE:-SMART warning detected}"
FULL="\${SMARTD_FULLMESSAGE:-\$MESSAGE}"

case "\$MESSAGE" in
    *FAILED*|*FAIL*|*failed*|*failure*|*uncorrectable*|*UNCORRECTABLE*|*critical*|*CRITICAL*)
        PRIORITY='urgent'
        TAGS='rotating_light,warning,computer_disk'
        STATUS='🔴 CRITICAL'
        ;;
    *)
        PRIORITY='high'
        TAGS='warning,computer_disk'
        STATUS='🟠 WARNING'
        ;;
esac

BODY="## 💽 SMART Disk Alert

**Host:** \\\`\$HOST\\\`
**Device:** \\\`\$DEVICE\\\`
**Type:** \\\`\$DEVTYPE\\\`
**Status:** \$STATUS
**Time:** \$(date)

### ⚠️ SMART Event

\$MESSAGE

### Details

\\\`\\\`\\\`
\$FULL
\\\`\\\`\\\`

---
smartd disk-health monitor"

curl -fsS -o /dev/null \
    -H "Authorization: Bearer \$NTFY_TOKEN" \
    -H "Title: 💽 SMART alert · \$HOST · \$DEVICE" \
    -H "Priority: \$PRIORITY" \
    -H "Tags: \$TAGS" \
    -H "Markdown: yes" \
    --data-binary "\$BODY" \
    "\$NTFY_URL"

logger -t ntfy-smartd "SMART event on \$DEVICE: \$MESSAGE"
SCRIPT

chmod 700 /usr/local/sbin/ntfy-smartd

cat >"$SMARTCONF" <<'SMART'
DEVICESCAN -a -o on -S on -n standby,q -m <nomailer> -M exec /usr/local/sbin/ntfy-smartd
SMART

if [ "$OS" = "FreeBSD" ]; then
    sysrc smartd_enable=YES >/dev/null

    service smartd stop >/dev/null 2>&1 || true

    if service smartd start; then
        echo "smartd started successfully."
    else
        echo
        echo "smartd failed to start."
        echo "Run:"
        echo "  sudo smartd -q onecheck -c /usr/local/etc/smartd.conf"
    fi
else
    systemctl enable smartd >/dev/null 2>&1 || true
    systemctl restart smartd
fi

echo
echo "========================================"
echo " SMART → ntfy monitoring installed"
echo "========================================"
echo
echo "Detected disks:"
smartctl --scan || true

echo
echo "Sending SMART test notification..."

SMARTD_DEVICE='/dev/test' \
SMARTD_DEVICETYPE='test' \
SMARTD_MESSAGE='SMART monitoring test successful' \
SMARTD_FULLMESSAGE='smartd ntfy integration is installed and able to send alerts.' \
/usr/local/sbin/ntfy-smartd

echo
echo "Done."
EOF
