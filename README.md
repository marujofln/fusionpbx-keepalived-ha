# FusionPBX Keepalived HA

Active/passive high availability for FreeSWITCH/FusionPBX using [keepalived](https://www.keepalived.org) (VRRP). The node holding the virtual IPs runs FreeSWITCH; the standby keeps it stopped. On failover the new master starts FreeSWITCH and issues `sofia recover` to restore calls.

## Files

| File | Purpose |
|---|---|
| [`ka-status.sh`](ka-status.sh) | VRRP health check (`track_script`). On the node holding a VIP it requires `fs_cli` to answer and the Sofia profiles `fs_profile_internal` and `fs_profile_external` to be `RUNNING`. Without a VIP it always succeeds, so a standby with FreeSWITCH stopped can still take over. |
| [`ka-notify.sh`](ka-notify.sh) | VRRP notify script. `MASTER` → start FreeSWITCH + `sofia recover`. `BACKUP` / `FAULT` / `STOP` → stop FreeSWITCH. |
| [`install-on-node.sh`](install-on-node.sh) | Installer: backs up `/etc/keepalived` and the runtime state, installs the scripts and sudoers rule, and patches `keepalived.conf`. |
| [`sudoers.keepalived-freeswitch`](sudoers.keepalived-freeswitch) | Lets `www-data` (the keepalived `script_user`) start/stop FreeSWITCH via `systemctl`. |
| [`keepalived.conf.pri.example`](keepalived.conf.pri.example), [`keepalived.conf.sec.example`](keepalived.conf.sec.example) | Reference configs for the primary and secondary nodes (two VIPs in one sync group). |
| [`INSTALL.md`](INSTALL.md) | Step-by-step manual procedure (Portuguese). |

## How it works

- Two `vrrp_instance`s (internal network and SBC network) live in one `vrrp_sync_group`, so both VIPs always move together.
- `ka-status.sh` runs every 5 s; with `fall 6` a node fails over about 30 s after a profile goes down.
- **Startup grace:** when a node becomes MASTER, `ka-notify.sh` writes a timestamp to `/tmp/ka-fs-grace-until` (90 s by default). During that window `ka-status.sh` ignores `fs_cli`/profile failures, so the new master is not demoted while FreeSWITCH is still starting.
- **No flapping:** every instance uses `state BACKUP` + `nopreempt`. keepalived ignores `nopreempt` when the initial state is `MASTER`, which would make the higher-priority node grab the VIP back right after recovering from a fault.

## Installation

Install on the **secondary first**, then on the primary, one node at a time. As root on each node:

```bash
# on your workstation
git clone https://github.com/marujofln/fusionpbx-keepalived-ha.git
cd fusionpbx-keepalived-ha
scp install-on-node.sh ka-status.sh ka-notify.sh sudoers.keepalived-freeswitch root@<node>:/tmp/

# then, as root on the node
bash /tmp/install-on-node.sh
```

The installer:

1. Backs up `/etc/keepalived`, the sudoers fragment, service status, `ip addr` and `sofia xmlstatus` to `/root/keepalived-backup-YYYYMMDD-HHMMSS/`.
2. Installs the scripts into `/etc/keepalived/` (`root:www-data`, mode 750) and the sudoers rule into `/etc/sudoers.d/` (validated with `visudo`).
3. Patches `/etc/keepalived/keepalived.conf`:
   - repoints `ka-status.pl` / `ka-notify.pl` to the `.sh` scripts;
   - adds `nopreempt`;
   - sets `priority 255` on all instances;
   - changes `state MASTER` to `state BACKUP`.
4. Validates the config (`keepalived -t`) and dry-runs `ka-status.sh` as `www-data`.

It does **not** reload keepalived. Activate each node when ready:

```bash
systemctl reload keepalived
```

> Reloading on the standby **stops FreeSWITCH** on that node; this is expected in active/passive mode.

Verify:

```bash
systemctl is-active freeswitch keepalived
ip -br a
journalctl -t ka-notify -t ka-status -n 30 --no-pager
```

## Rollback

```bash
BACKUP=/root/keepalived-backup-TIMESTAMP   # path printed by the installer
cp -a "$BACKUP/keepalived/"* /etc/keepalived/
rm -f /etc/sudoers.d/keepalived-freeswitch # if it did not exist before
systemctl reload keepalived
```

## Customizing

- **VIPs:** edit `VIP_MARKERS` in `ka-status.sh` (and the regex in `vip_present()` in `ka-notify.sh`) to match your virtual IPs.
- **Profiles:** edit `REQUIRED_PROFILES` in `ka-status.sh`.
- **Environment overrides:** `FS_CLI`, `SYSTEMCTL`, `FREESWITCH_SERVICE`, `KA_GRACE_FILE`, `KA_STARTUP_GRACE_SEC`, `KA_DEBUG_LOG`.
- **`auth_pass`:** the example configs use `CHANGE_ME`. Set your own secret, identical on both nodes.

## Recommendations

- Set FreeSWITCH to `disabled` at boot on both nodes and let `ka-notify.sh` start and stop it.
- Keep `fall` ≥ 6 even with the startup grace. `fall 2` is only safe while the grace stamp is working.
- With `nopreempt`, failback to the primary only happens when the current master fails or its keepalived is restarted.
