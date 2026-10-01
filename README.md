
# ntfy Infrastructure Monitoring Scripts

Small monitoring scripts for Linux and FreeBSD that send alerts to an ntfy server.

These scripts are designed for simple self-hosted infrastructure monitoring without requiring a full monitoring stack.

## Included monitors

### Monero / Docker node monitor

Monitors a Docker-based Monero node and p2pool setup.

Checks include:

- `monerod` container running state
- Docker health status
- Monero RPC health
- block height progression
- synchronization status
- stalled blockchain detection
- `p2pool-mini` container health
- host network bandwidth
- recovery notifications

The monitor is designed to work with rootless Docker.

Default assumptions:

```text
monerod container: monerod
p2pool container: p2pool-mini
Monero RPC inside container: 127.0.0.1:18089
Block stall threshold: 15 minutes
Bandwidth threshold: 500 Mbps
Check interval: 5 minutes
