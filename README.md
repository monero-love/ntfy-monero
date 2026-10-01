# ntfy Infrastructure Monitoring Scripts

Lightweight monitoring scripts for Linux and FreeBSD that send alerts to an ntfy server.

These scripts are intended for self-hosted infrastructure, Monero nodes, Docker hosts, homelabs, and small servers.

They can monitor:

- Monero node health
- Monero block-height progression
- p2pool container health
- Tor connectivity
- Docker container state
- SMART disk health
- package and security updates
- failed services
- bandwidth usage
- service recovery

## Monero Monitoring

The Monero monitor can check:

- `monerod` process or container status
- Docker health state
- Monero RPC availability
- blockchain height
- block-height progression
- synchronization state
- offline mode
- transaction pool size
- stalled chain detection
- recovery after a failure

Typical settings:

```text
Check interval: 5 minutes
Block stall threshold: 15 minutes
```

Example healthy state:

```text
Host: node1-eu
Status: HEALTHY

monerod
  Container: running
  Docker health: healthy
  RPC: healthy
  Height: 3774209
  Network: mainnet
  Sync: synchronized
  Chain progress: advancing
```

## p2pool Monitoring

The default p2pool container name is:

```text
p2pool-mini
```

Checks include:

- container exists
- container is running
- Docker health state
- recovery notification when service returns

## Rootless Docker Support

The Docker monitor supports rootless Docker.

If Docker runs as a normal user such as `user`, the Docker socket may be:

```text
/run/user/1000/docker.sock
```

A systemd service should use the rootless Docker user's environment:

```ini
[Service]
User=baz
Group=baz
Environment=HOME=/home/user
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=DOCKER_HOST=unix:///run/user/1000/docker.sock
```

Check the user's UID:

```sh
id -u user
```

Test rootless Docker manually:

```sh
sudo -u user env \
  HOME=/home/baz \
  XDG_RUNTIME_DIR=/run/user/$(id -u user) \
  DOCKER_HOST=unix:///run/user/$(id -u baz)/docker.sock \
  docker ps
```

## Monero RPC

Some Docker Monero images expose restricted RPC internally on port `18089`.

If host-side Docker port forwarding does not behave correctly, query the RPC from inside the container:

```sh
docker exec monerod sh -c \
  'wget -qO- http://127.0.0.1:18089/get_info 2>/dev/null || curl -fsS http://127.0.0.1:18089/get_info'
```

Pretty output:

```sh
docker exec monerod sh -c \
  'wget -qO- http://127.0.0.1:18089/get_info 2>/dev/null || curl -fsS http://127.0.0.1:18089/get_info' \
  | jq .
```

Useful fields include:

```text
height
synchronized
offline
busy_syncing
tx_pool_size
nettype
update_available
```

## Block-Height Monitoring

The monitor stores the previous Monero block height.

If the height changes:

```text
Chain progress: advancing
```

If it remains unchanged briefly:

```text
Same height for 5 minutes
```

If it remains unchanged longer than the configured stall threshold:

```text
Chain progress: stalled 15 minutes
```

Typical setting:

```sh
STALL_SECONDS=900
```

## Tor Monitoring

Some versions of the monitor support Tor.

Checks may include:

- Tor process running
- SOCKS proxy available
- SOCKS port `9050`
- outbound traffic through Tor
- Tor Project verification
- Tor exit IP

Test manually:

```sh
curl \
  --socks5-hostname 127.0.0.1:9050 \
  https://check.torproject.org/api/ip
```

A healthy response should contain:

```json
{
  "IsTor": true
}
```

If a host does not run Tor, disable Tor checks instead of leaving the host permanently degraded.

## FreeBSD Tor Troubleshooting

Verify config as the Tor user:

```sh
sudo -u _tor /usr/local/bin/tor --verify-config
```

or:

```sh
su -m _tor -c '/usr/local/bin/tor --verify-config'
```

Check Tor:

```sh
service tor status
```

Check process:

```sh
pgrep -a tor
```

Check SOCKS listener:

```sh
sockstat -4 -6 -l | grep 9050
```

Check logs:

```sh
grep -Ei 'tor|bootstrapped|warn|err' /var/log/messages | tail -100
```

A fully bootstrapped Tor daemon should eventually report:

```text
Bootstrapped 100% (done)
```

## Bandwidth Monitoring

The bandwidth monitor samples RX and TX byte counters on the default interface.

Typical settings:

```text
Threshold: 500 Mbps
Sample interval: 60 seconds
Alert cooldown: 15 minutes
```

Suggested starting thresholds:

```text
1 GbE     700 Mbps
2.5 GbE   1800 Mbps
10 GbE    7000 Mbps
```

Adjust these for your environment.

## SMART Disk Monitoring

SMART monitoring uses:

```text
smartmontools
smartd
smartctl
```

Typical alerts include:

- SMART overall-health failures
- reallocated sectors
- pending sectors
- uncorrectable sectors
- SMART self-test failures
- SMART error-log changes
- disk-health warnings

### Install smartmontools

Arch Linux:

```sh
sudo pacman -S --needed smartmontools curl
```

Debian / Ubuntu:

```sh
sudo apt update
sudo apt install smartmontools curl
```

FreeBSD:

```sh
sudo pkg install smartmontools curl
```

### smartd Configuration

Linux:

```text
/etc/smartd.conf
```

FreeBSD:

```text
/usr/local/etc/smartd.conf
```

Example:

```text
DEVICESCAN -a -o on -S on -n standby,q -m <nomailer> -M exec /usr/local/sbin/ntfy-smartd
```

Check detected devices:

```sh
sudo smartctl --scan
```

Linux:

```sh
sudo systemctl enable --now smartd
systemctl status smartd --no-pager
journalctl -u smartd -n 100 --no-pager
```

FreeBSD:

```sh
sudo sysrc smartd_enable=YES
sudo service smartd start
sudo service smartd status
grep -i smartd /var/log/messages | tail -100
```

Test SMART ntfy manually:

```sh
sudo env \
SMARTD_DEVICE=/dev/test \
SMARTD_DEVICETYPE=test \
SMARTD_MESSAGE="SMART monitoring test" \
SMARTD_FULLMESSAGE="This is a test SMART alert." \
/usr/local/sbin/ntfy-smartd
```

## Security Auditing

### Arch Linux / CachyOS

Uses:

```text
arch-audit
pacman
```

All known issues:

```sh
arch-audit
```

Issues with a fixed package available:

```sh
arch-audit -u
```

Pending upgrades:

```sh
pacman -Qu
```

A package can appear in `arch-audit` even when no fixed package is available yet.

### Debian / Ubuntu

Typical tools:

```text
debsecan
apt
```

Check upgrades:

```sh
apt list --upgradable
```

### FreeBSD

Uses:

```sh
pkg audit
```

Example:

```sh
sudo pkg audit -F
```

Check package versions:

```sh
pkg version -vRL=
```

## Failed System Services

On systemd Linux hosts:

```sh
systemctl --failed
```

These failures can be included in ntfy infrastructure alerts.

## ntfy Configuration

Typical variables:

```sh
NTFY_URL='https://ntfy.example.com/infra-warning'
NTFY_TOKEN='YOUR_TOKEN'
```

Manual test:

```sh
curl \
  -H "Authorization: Bearer $NTFY_TOKEN" \
  -H "Title: Monitoring test" \
  -H "Priority: high" \
  -d "Test from $(hostname)" \
  "$NTFY_URL"
```

## Alert Priorities

Suggested priorities:

```text
urgent
  disk failure
  critical security update

high
  Monero node degraded
  Tor failure
  high bandwidth
  failed service

default
  recovery event
  normal package updates

low
  known vulnerability with no fix
  test notifications

min
  healthy status
```

## Recovery Notifications

Typical state behavior:

```text
Healthy -> Healthy
  no notification

Healthy -> Failed
  send alert

Failed -> Failed
  do not repeatedly spam

Failed -> Healthy
  send recovery notification
```

## Systemd Timers

Example:

```ini
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=20s
Persistent=true
```

Enable:

```sh
sudo systemctl enable --now ntfy-monero-monitor.timer
```

Check:

```sh
systemctl list-timers --all | grep ntfy
```

## Manual Checks

Run Monero monitor:

```sh
sudo systemctl start ntfy-monero-monitor.service
```

View logs:

```sh
journalctl \
  -u ntfy-monero-monitor.service \
  -n 50 \
  --no-pager
```

For rootless Docker:

```sh
sudo -u baz env \
  HOME=/home/baz \
  XDG_RUNTIME_DIR=/run/user/$(id -u baz) \
  DOCKER_HOST=unix:///run/user/$(id -u baz)/docker.sock \
  /usr/local/sbin/ntfy-monero-monitor
```

## FreeBSD Scheduling

FreeBSD versions may use cron.

Example:

```cron
*/5 * * * * /usr/local/sbin/ntfy-node-monitor >/dev/null 2>&1
```

Check:

```sh
sudo crontab -l
```

## Duplicate Alert Troubleshooting

Check systemd timers:

```sh
systemctl list-timers --all | grep -Ei 'ntfy|monero|tor'
```

Check installed units:

```sh
systemctl list-unit-files | grep -Ei 'ntfy|monero|tor'
```

Check cron:

```sh
sudo crontab -l
crontab -l
```

Search for old scripts:

```sh
sudo grep -RniE \
  'ntfy|monero|tor|18081|18089' \
  /etc/systemd \
  /usr/local/bin \
  /usr/local/sbin \
  /etc/cron* \
  /var/spool/cron \
  2>/dev/null
```

Possible obsolete units include:

```text
ntfy-monero-tor-check.timer
ntfy-monero-tor-check.service
ntfy-node-monitor.timer
ntfy-node-monitor.service
ntfy-docker-monero-tor.timer
ntfy-docker-monero-tor.service
ntfy-bandwidth-monitor.timer
ntfy-bandwidth-monitor.service
```

Disable an old timer with:

```sh
sudo systemctl disable --now NAME.timer
```

## Docker Diagnostics

Show containers:

```sh
docker ps
```

Compact view:

```sh
docker ps \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Check monerod:

```sh
docker inspect \
  -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
  monerod
```

Check p2pool:

```sh
docker inspect \
  -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
  p2pool-mini
```

## Monero Diagnostics

Get node information:

```sh
docker exec monerod sh -c \
  'wget -qO- http://127.0.0.1:18089/get_info'
```

Useful summary:

```sh
docker exec monerod sh -c \
  'wget -qO- http://127.0.0.1:18089/get_info' \
  | jq '{
      height,
      synchronized,
      busy_syncing,
      offline,
      tx_pool_size,
      nettype
  }'
```

## File Locations

Typical Linux layout:

```text
/usr/local/sbin/ntfy-monero-monitor
/usr/local/sbin/ntfy-smartd
/usr/local/sbin/ntfy-infra-audit
/usr/local/sbin/ntfy-bandwidth-monitor

/etc/systemd/system/ntfy-monero-monitor.service
/etc/systemd/system/ntfy-monero-monitor.timer

/etc/smartd.conf

/var/lib/ntfy-monero-monitor/
```

Typical FreeBSD layout:

```text
/usr/local/sbin/ntfy-node-monitor
/usr/local/sbin/ntfy-smartd
/usr/local/etc/smartd.conf
```

## Permissions

Scripts containing ntfy tokens should not be world-readable.

Example:

```sh
sudo chmod 700 /usr/local/sbin/ntfy-smartd
```

For a rootless Docker monitor:

```sh
sudo chown root:baz /usr/local/sbin/ntfy-monero-monitor
sudo chmod 750 /usr/local/sbin/ntfy-monero-monitor
```

## Secrets

Do not commit real ntfy tokens into a public Git repository.

Recommended `.gitignore`:

```gitignore
.env
.env.*
*.token
*.secret
config.local
secrets/
```

A better long-term setup is to keep credentials in a root-only configuration file, for example:

```text
/etc/ntfy-monitor.conf
```

Example:

```sh
NTFY_URL='https://ntfy.example.com/infra-warning'
NTFY_TOKEN='YOUR_TOKEN'
```

Permissions:

```sh
sudo chown root:root /etc/ntfy-monitor.conf
sudo chmod 600 /etc/ntfy-monitor.conf
```

## Supported Platforms

Intended platforms include:

```text
Arch Linux
CachyOS
EndeavourOS
Manjaro

Debian
Ubuntu
Linux Mint

FreeBSD
```

Individual scripts may support only a subset.

## Requirements

Depending on the script:

```text
curl
jq
smartmontools
Docker
systemd
arch-audit
debsecan
pkg
```

## Recommended Deployment

A typical Monero Docker host can use:

```text
ntfy-monero-monitor
  monerod Docker health
  Monero RPC health
  block-height progression
  p2pool health
  bandwidth monitoring

smartd
  disk SMART monitoring

ntfy-infra-audit
  security updates
  vulnerable packages
  failed system services
```

## Security Notes

Recommended practices:

- use ntfy access tokens instead of passwords
- never publish real tokens in Git
- rotate exposed tokens
- use restrictive file permissions
- use restricted Monero RPC where possible
- do not expose unrestricted Monero RPC publicly
- monitor blockchain progression instead of only checking if `monerod` exists
- use SMART monitoring for physical storage
- keep operating-system packages updated

## License

Use, modify, and adapt these scripts for your own infrastructure.

Before publishing, remove:

- private ntfy URLs
- access tokens
- internal hostnames
- private IP addresses
- usernames specific to your environment
