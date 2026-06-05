# 03 — Configuring sFlow on Nutanix AHV Hosts

This document covers the sFlow configuration on each AHV host's Open vSwitch (OVS) instance. It is the most important configuration in the entire stack — get this right and the rest is easy.

---

## Background: OVS Bridges on AHV

A Nutanix AHV host runs Open vSwitch and creates multiple bridges, each with a specific purpose. The exact list varies by AHV version and Flow Networking deployment, but you'll typically see:

| Bridge | Purpose | sFlow target? |
|--------|---------|---------------|
| `br0` | Primary external bridge — uplinks to the physical network | **Yes** — carries VM north-south traffic |
| `br0.local` | Local intra-host VM bridge | **Yes** — carries intra-host east-west traffic |
| `brAtlas` | Atlas / Flow Networking overlay bridge | **Yes** — carries Flow Networking traffic |
| `br1`, `br1.local` | Secondary uplink (if present) | **Yes if VMs use it** |
| `brSpan` | Mirror/SPAN destination | No — no VM traffic |
| `br.nf`, `br.mx`, `br.microseg`, `br.dmx` | Internal system bridges | No — system/control plane |

**Critical insight:** if you only attach sFlow to `br0`, you will miss 60–80% of VM-to-VM traffic, which lives on `br0.local` and `brAtlas`. Multi-bridge attach is mandatory for meaningful visibility.

To inspect your host's bridges:

```bash
ovs-vsctl list-br
```

To see which bridges have VM taps:

```bash
for br in $(ovs-vsctl list-br); do
  count=$(ovs-vsctl list-ports $br | grep -E '^(tap|vnet)' | wc -l)
  echo "$br: $count VM ports"
done
```

---

## The Standard Configuration

A single OVS transaction creates the sFlow record and attaches it to all VM-bearing bridges atomically:

```bash
ovs-vsctl -- --id=@sf create sflow \
  targets='["<COLLECTOR_IP>:6344"]' \
  header=512 \
  sampling=1024 \
  polling=20 \
  -- set bridge br0 sflow=@sf \
  -- set bridge br0.local sflow=@sf \
  -- set bridge brAtlas sflow=@sf
```

Replace `<COLLECTOR_IP>` with the IP of your Akvorado collector VM.

### What each parameter means

| Parameter | Recommended value | What it does |
|-----------|-------------------|--------------|
| `targets` | `["<IP>:6344"]` | List of `IP:port` collectors. Multiple supported — sFlow datagrams are sent to all. |
| `header` | `512` | Bytes of packet header captured per sample. 128 is minimum useful, 512 captures TLS SNI and HTTP first line. |
| `sampling` | `1024` | 1-in-N packet sampling. See sampling rate guide below. |
| `polling` | `20` | Counter samples (interface stats) sent every N seconds. |
| `agent` | (omitted) | Source IP for sFlow datagrams. Leave unset — OVS picks automatically. |

### Sampling rate guide

| Rate | Use case | Notes |
|------|----------|-------|
| 1–10 | Forensic deep-dive on a single host | Too heavy for sustained use. |
| 512 | Aggressive lab visibility | Catches even very quiet VMs. |
| **1024** | **Recommended lab / small cluster default** | Best balance of visibility and overhead. |
| 2000 | Production with moderate traffic | Standard for many production deployments. |
| 4096 | High-traffic clusters (>10 Gbps sustained) | Reduces collector load. |

A general rule: at line-rate 10 Gbps with average 500-byte packets (~2.5 Mpps), `sampling=1024` produces ~2,400 samples per second per host. The Akvorado inlet handles 100,000+ samples/sec per worker without strain, so even at sampling=512 you have substantial headroom.

---

## Verification on Each Host

### List the sFlow record

```bash
ovs-vsctl list sflow
```

Expected output:

```
_uuid               : <some-uuid>
agent               : []
external_ids        : {}
header              : 512
polling             : 20
sampling            : 1024
targets             : ["<COLLECTOR_IP>:6344"]
```

### Confirm bridge attachments

```bash
for br in br0 br0.local brAtlas; do
  echo -n "$br: "
  ovs-vsctl get bridge $br sflow
done
```

All three bridges should show the same UUID. If any shows `[]`, the attachment didn't take.

### Confirm packets are leaving the host

```bash
# Replace eth0 with the actual management interface
sudo tcpdump -nn -i any -c 20 'udp port 6344 and dst host <COLLECTOR_IP>'
```

You should see UDP packets leaving the host within seconds.

---

## Removing or Updating sFlow Config

### Remove sFlow from a single bridge

```bash
ovs-vsctl clear bridge <bridge> sflow
```

### Remove all sFlow configuration on a host

```bash
# Detach from all bridges
for br in $(ovs-vsctl list-br); do
  ovs-vsctl clear bridge $br sflow
done

# Destroy the sFlow record itself
for uuid in $(ovs-vsctl --columns=_uuid find sflow | awk '/_uuid/{print $3}'); do
  ovs-vsctl destroy sflow $uuid
done
```

### Update an existing sFlow record's parameters

```bash
# Get the existing UUID
SFLOW_UUID=$(ovs-vsctl --columns=_uuid find sflow | awk '/_uuid/{print $3}' | head -1)

# Update individual parameters
ovs-vsctl set sflow $SFLOW_UUID sampling=2000
ovs-vsctl set sflow $SFLOW_UUID polling=30
ovs-vsctl set sflow $SFLOW_UUID targets='["new-collector:6344"]'
```

Changes take effect immediately — no restart needed.

---

## Persistence Across Reboots

OVS sFlow configuration is stored in the OVSDB and persists across host reboots. **No additional steps are needed** to make the configuration durable.

This is true for AHV releases that maintain a writable OVSDB across the AOS lifecycle. If your hosts revert OVS configuration on upgrade (rare but possible on highly customized images), consider adding the `ovs-vsctl` commands to a host-startup script.

---

## NetFlow vs sFlow on the Same Bridge

OVS supports both NetFlow and sFlow on the same bridge simultaneously. If you want to use this stack alongside NetFlow for compliance/audit purposes, you can keep both enabled:

```bash
# sFlow (already configured per above)

# Add NetFlow output
ovs-vsctl -- --id=@nf create netflow targets='["<COLLECTOR>:2055"]' active-timeout=60 \
  -- set bridge br0 netflow=@nf \
  -- set bridge br0.local netflow=@nf \
  -- set bridge brAtlas netflow=@nf
```

If you instead want to ensure **only sFlow** is sending (the recommended setup for this stack), explicitly remove any existing NetFlow:

```bash
for br in $(ovs-vsctl list-br); do
  ovs-vsctl clear bridge $br netflow
done

for uuid in $(ovs-vsctl --columns=_uuid find netflow | awk '/_uuid/{print $3}'); do
  ovs-vsctl destroy netflow $uuid
done
```

See [`01-architecture.md`](01-architecture.md) for the rationale on choosing sFlow.

---

## Why This Setup Survives AHV Upgrades

The configuration uses standard OVS commands (`ovs-vsctl`), not any Nutanix-specific tooling. The OVSDB persists across:

- AHV host reboots
- LCM (Life Cycle Manager) upgrades of AHV
- AOS upgrades
- Single-host or rolling cluster operations

The only scenarios where you'd need to reapply:

- Complete host re-imaging (factory reset)
- OVSDB corruption requiring re-initialization

For both scenarios, treat the sFlow configuration as part of host post-build automation.

---

## Helper Script

A helper script that wraps the standard configuration with verification is available at [`scripts/ahv-sflow-setup.sh`](../scripts/ahv-sflow-setup.sh). It is idempotent (safe to re-run), removes any existing sFlow/NetFlow first, then reapplies the standard configuration.

---

## Common Pitfalls

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Packets arrive at the collector but no flows appear | `sampling=0` — only counter samples sent | Set `sampling` to a non-zero value (1024 recommended) |
| Only some bridges send sFlow | Forgot to attach to all VM-bearing bridges | Verify with the `for` loop above |
| sFlow datagrams from wrong source IP | `agent` field was set explicitly | Clear it: `ovs-vsctl set sflow <UUID> agent=[]` |
| sFlow drops on host reboot | Custom AHV image overwrites OVSDB | Add commands to host-startup automation |
| `ovs-appctl sflow/show` returns "not a valid command" | AHV's OVS build doesn't include the appctl helper | Use `ovs-vsctl list sflow` instead |

For more, see [`06-troubleshooting.md`](06-troubleshooting.md).
