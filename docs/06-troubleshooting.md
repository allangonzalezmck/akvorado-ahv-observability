# 06 — Troubleshooting Guide

Real issues we hit while building this stack, with the diagnostic procedure and the fix for each. Several took days to figure out — hopefully this saves you the time.

---

## Issue 1: Packets Arrive at the Collector but No Flows in ClickHouse

### Symptoms

```bash
# tcpdump on the collector VM shows packets:
sudo tcpdump -nn -i any 'udp port 6344'
# 23:14:01.123456 IP 10.1.2.3.43380 > 10.5.6.7.6344: UDP, length 1228
# (many similar lines)

# But ClickHouse shows zero flows from this exporter:
docker exec docker-clickhouse-1 clickhouse-client --query "
SELECT count() FROM flows WHERE ExporterAddress = toIPv6('::ffff:10.1.2.3')"
# 0
```

### Diagnosis

Check the inlet metrics first to see if Akvorado received the packets:

```bash
INLET_IP=$(docker inspect docker-akvorado-inlet-1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
curl -s http://$INLET_IP:8080/api/v0/inlet/metrics | grep "10.1.2.3"
```

If you see entries for the exporter in `akvorado_inlet_flow_input_udp_*` and `akvorado_inlet_kafka_sent_messages_total`, the inlet decoded the flows and sent them to Kafka. The problem is downstream — in the outlet.

### Root Cause

The outlet's metadata enrichment stage drops flows from exporters that don't match any entry in `outlet.metadata.providers.static.exporters`.

This is the single most surprising behavior in Akvorado. The `outlet.metadata` block is presented in many tutorials as "purely for enrichment / labeling," but in practice, **unmatched exporters get their flows discarded**.

### Fix

Always include catchall CIDR entries in your outlet metadata config:

```yaml
outlet:
  metadata:
    providers:
      - type: static
        exporters:
          # ... your specific clusters ...

          # Catchall — matches anything not above
          "0.0.0.0/0":
            name: "unclassified-exporter"
            group: "unclassified"
            role: "unknown"
            site: "unknown"
            region: "unknown"
            tenant: "unknown"
            default:
              name: "unknown"
              description: "unknown"
              speed: 10000

          "::/0":
            name: "unclassified-exporter"
            group: "unclassified"
            role: "unknown"
            site: "unknown"
            region: "unknown"
            tenant: "unknown"
            default:
              name: "unknown"
              description: "unknown"
              speed: 10000
```

Then restart:

```bash
docker compose restart akvorado-orchestrator akvorado-outlet
```

Flows from the previously-unmatched exporter should appear within seconds.

---

## Issue 2: sFlow Datagrams Arrive but No Flow Samples Decoded

### Symptoms

- Inlet metrics show bytes/packets received from the exporter.
- `akvorado_inlet_kafka_sent_messages_total` for this exporter is zero or very low.
- The flow record count in ClickHouse stays at zero or grows extremely slowly.

### Diagnosis

This means Akvorado is receiving sFlow datagrams but not finding flow samples inside them. The datagrams contain only counter samples.

Check the OVS sFlow configuration on the affected host:

```bash
ovs-vsctl list sflow
```

Look at the `sampling` field. If it's `0` or empty:

```
sampling : 0
```

…then OVS is only sending counter samples (interface stats), not packet samples. There's nothing for Akvorado to decode into flow records.

### Fix

Set a non-zero sampling rate:

```bash
SFLOW_UUID=$(ovs-vsctl --columns=_uuid find sflow | awk '/_uuid/{print $3}' | head -1)
ovs-vsctl set sflow $SFLOW_UUID sampling=1024
```

See [`03-ahv-sflow-configuration.md`](03-ahv-sflow-configuration.md) for the sampling rate guide.

---

## Issue 3: Containers Crash-Loop on Startup After Config Change

### Symptoms

After editing `akvorado.yaml`:

```bash
docker compose ps
# NAME                             STATUS
# docker-akvorado-orchestrator-1   Restarting (1)
# docker-akvorado-outlet-1         Restarting (1)
```

### Diagnosis

```bash
docker logs docker-akvorado-orchestrator-1 --tail 30
```

You'll see a clear error message, usually one of:

| Error pattern | Cause |
|---------------|-------|
| `has invalid keys: <fieldname>` | A field name that doesn't exist in the Akvorado schema |
| `unmarshal errors` / `cannot unmarshal` | YAML syntax error or wrong type for a field |
| `could not determine a constructor for the tag '!include'` | YAML parsed by standard tooling that doesn't know about Akvorado's custom `!include` directive |

### Fix

Always validate before restarting:

```bash
cd /srv/fast/workspace/akvorado/docker
docker compose run --rm akvorado-orchestrator orchestrator /etc/akvorado/akvorado.yaml --check 2>&1 | tail -20
```

This uses Akvorado's own parser. If it returns clean, the config is valid.

If you want a quick syntax-only check (handles `!include`):

```bash
python3 -c "
import yaml
class L(yaml.SafeLoader): pass
L.add_constructor(None, lambda l, n: None)
yaml.load(open('/srv/fast/workspace/akvorado/config/akvorado.yaml'), Loader=L)
print('YAML OK')
"
```

The `add_constructor(None, ...)` trick tells PyYAML to ignore any custom tags.

---

## Issue 4: Only Two Exporters Show in the Akvorado UI Despite Many Hosts

### Symptoms

You configured sFlow on 6 (or 60, or 600) AHV hosts. The UI's Visualize tab only shows 2 distinct entries.

### Diagnosis

This is a UI behavior, not an ingestion problem. The default Visualize view groups by `ExporterName`, which is bucketed by the CIDR in your outlet metadata config. If all 6 hosts are in `10.1.1.0/24` and you configured one entry for that CIDR, they all collapse into one `ExporterName` bucket.

Verify by querying ClickHouse directly:

```bash
docker exec docker-clickhouse-1 clickhouse-client --query "
SELECT
  IPv6NumToString(ExporterAddress) AS exporter,
  count() AS flows
FROM flows
WHERE TimeReceived > now() - INTERVAL 5 MINUTE
GROUP BY exporter
ORDER BY exporter"
```

If all 6 hosts appear here, ingestion is fine — the UI just isn't showing them by default.

### Fix

In the Akvorado UI Visualize tab:

1. Add `ExporterAddress` to the Dimensions
2. Set Limit to a number larger than your host count (e.g., 50)
3. Set Time range to at least 30 minutes (default 5-min window can miss bursty hosts)
4. Click Apply / Refresh

You now see per-host detail. Use `ExporterName` for cluster-level aggregations, `ExporterAddress` for per-host detail.

---

## Issue 5: Only NetFlow Showing, sFlow Apparently Missing

### Symptoms

ClickHouse has lots of flow records, but they all seem to be from NetFlow (port 2055). sFlow datagrams arrive at the collector (tcpdump confirms) but the UI doesn't appear to show them.

### Diagnosis

There's no explicit "protocol" column in the Akvorado flows schema. NetFlow and sFlow records are stored together. The way to differentiate is by `SamplingRate`:

```bash
docker exec docker-clickhouse-1 clickhouse-client --query "
SELECT SamplingRate, count() AS flows
FROM flows
WHERE TimeReceived > now() - INTERVAL 5 MINUTE
GROUP BY SamplingRate
ORDER BY flows DESC"
```

- `SamplingRate = 0` typically means NetFlow (unsampled).
- `SamplingRate = 1024` (or whatever you configured) is sFlow.

If sFlow values are present, sFlow is working — your filter in the UI just isn't isolating them.

### Fix

In the UI Visualize tab, filter:

```
SamplingRate = 1024
```

Replace 1024 with your configured sFlow sampling rate. The chart now shows only sFlow data.

---

## Issue 6: YAML Validator Crashes on `!include` Tag

### Symptoms

```
yaml.constructor.ConstructorError: could not determine a constructor for the tag '!include'
```

### Cause

Akvorado uses a custom YAML directive `!include "filename"` to import inlet configuration into the main file. Standard YAML parsers don't recognize it.

### Fix

Use Akvorado's own validator (preferred):

```bash
docker compose run --rm akvorado-orchestrator orchestrator /etc/akvorado/akvorado.yaml --check
```

Or use a Python validator that ignores unknown tags:

```bash
python3 -c "
import yaml
class L(yaml.SafeLoader): pass
L.add_constructor(None, lambda l, n: None)
yaml.load(open('/srv/fast/workspace/akvorado/config/akvorado.yaml'), Loader=L)
print('YAML OK')
"
```

---

## Issue 7: Schema Field Errors Like "has invalid keys: description"

### Symptoms

```
docker compose run --rm akvorado-orchestrator orchestrator ... --check
# 10.1.0.0/24 has invalid keys: description
```

### Cause

Akvorado's static metadata exporter schema is strict. Only specific fields are allowed at the exporter level:

- `name`, `group`, `role`, `site`, `region`, `tenant`
- `default` (object)
- `ifaces` (object)

A top-level `description` field is NOT valid. It only exists inside `default:` and inside `ifaces:` entries.

### Fix

Move any descriptive text to YAML comments:

```yaml
# BAD (causes the error)
"10.1.0.0/24":
  name: "dc01-cl01-ahv"
  description: "Primary lab cluster"   # ← INVALID
  group: "dc01-lab"

# GOOD
# Primary lab cluster, DR-paired with DC02-CL01
"10.1.0.0/24":
  name: "dc01-cl01-ahv"
  group: "dc01-lab"
```

---

## Issue 8: Phantom Exporter (Docker Bridge IP) Showing in Inlet Metrics

### Symptoms

Inlet metrics show an exporter at `172.30.0.1` (or similar Docker bridge IP) with high packet counts.

### Cause

A container inside Akvorado's Docker network is sending sFlow back into the inlet. The source IP appears as the Docker bridge gateway because of how Docker NAT works.

This is usually harmless — it's typically Akvorado's own UDP echo or an internal probe. It does not appear in ClickHouse (the outlet filters it out).

### When to investigate

Only worry about this if:

- The phantom exporter is consuming significant resources
- You see correlation with degraded performance

In normal operation: ignore it.

---

## Issue 9: AHV's `ovs-appctl sflow/show` Doesn't Work

### Symptoms

```bash
ovs-appctl -t ovs-vswitchd sflow/show
# "sflow/show" is not a valid command
```

### Cause

Nutanix AHV ships with a customized Open vSwitch build that may not include certain `appctl` debug commands. This is normal.

### Fix

Use OVSDB-based commands instead:

```bash
# Show sFlow config
ovs-vsctl list sflow

# Show which bridges have sFlow attached
for br in $(ovs-vsctl list-br); do
  echo -n "$br: "; ovs-vsctl get bridge $br sflow
done
```

These give you all the same information.

---

## Issue 10: Different Hosts Send Different Amounts of sFlow Data

### Symptoms

Inlet metrics show host A sending 100 MB/min while host B sends only 3 MB/min, despite identical sFlow configuration.

### Cause

This is **normal** and expected — different hosts have different traffic volumes:

- Host A may have busy VMs (heavy database, web server)
- Host B may have idle VMs (test, development)

sFlow samples are proportional to traffic. The relationship is:

```
flow_records_per_second ≈ packets_per_second / sampling_rate
```

If host B has 1/30th the traffic of host A, you'll see 1/30th the data volume.

### When to investigate

Only worry if:

- All hosts should have similar traffic (e.g., identical workload pattern) but vary widely
- A host went silent suddenly when it was producing data before
- A host shows ZERO data (then check for `sampling=0` per Issue 2)

---

## General Debugging Procedure

When something doesn't work, run these in order:

```bash
# 1. Are packets arriving at the collector VM?
sudo tcpdump -nn -i any -c 20 'udp port 6344 and src host <EXPORTER_IP>'

# 2. Is Akvorado inlet seeing them?
INLET_IP=$(docker inspect docker-akvorado-inlet-1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
curl -s http://$INLET_IP:8080/api/v0/inlet/metrics | grep "<EXPORTER_IP>"

# 3. Are they being sent to Kafka?
curl -s http://$INLET_IP:8080/api/v0/inlet/metrics | grep "kafka_sent_messages.*<EXPORTER_IP>"

# 4. Are they reaching ClickHouse?
docker exec docker-clickhouse-1 clickhouse-client --query "
SELECT count() FROM flows
WHERE ExporterAddress = toIPv6('::ffff:<EXPORTER_IP>')
AND TimeReceived > now() - INTERVAL 5 MINUTE"

# 5. What does the orchestrator log say?
docker logs docker-akvorado-orchestrator-1 --tail 50

# 6. What does the outlet log say?
docker logs docker-akvorado-outlet-1 --tail 50
```

Identify the first step where data stops appearing — that pinpoints the failure stage.

---

## Getting Help

If you encounter an issue not covered here:

1. **Akvorado documentation:** https://demo.akvorado.net/docs
2. **Akvorado GitHub issues:** https://github.com/akvorado/akvorado/issues
3. **Open vSwitch sFlow docs:** https://docs.openvswitch.org/en/latest/howto/sflow/

If you solve a new issue, please contribute it back via a pull request to this troubleshooting guide.
