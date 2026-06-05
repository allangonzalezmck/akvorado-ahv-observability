# 01 — Architecture and Design Rationale

This document explains *why* the stack is built the way it is. Configuration details are in subsequent documents; this one is about decisions.

---

## The Problem

Nutanix AHV is an excellent virtualization platform but **does not natively expose per-flow telemetry** about VM-to-VM (east-west) traffic. The available data sources are limited:

- **Prism counters** — aggregate CVM/host-level metrics. No per-flow detail.
- **Flow Networking (Microseg)** — provides policy-level information about traffic that matches a rule. Does not capture traffic outside of policies.
- **Flow Networking visibility add-on** — limited to specific subscription tiers and provides aggregated, not packet-level, visibility.
- **Per-VM tcpdump** — manual, hard to scale, requires SSH to each AHV host.

For operations teams who need to:

- Investigate traffic storms (the original trigger for this project)
- Understand baseline traffic patterns before a major change
- Validate DR replication behavior
- Detect anomalies (port scans, beaconing, lateral movement, exfiltration)
- Plan capacity based on actual flow volumes

…the lack of native visibility is a serious gap. Commercial alternatives (Cisco Secure Workload, Gigamon, ExtraHop, Datadog Network Performance Monitoring) exist but range from $80,000 to $500,000+ per cluster per year.

This project demonstrates that the gap can be closed with **open-source software**, **no SaaS dependency**, and **production-grade scalability**.

---

## The Solution at a Glance

Three components do the heavy lifting:

1. **Open vSwitch (OVS) sFlow agent** — already present in every AHV host. We just configure it.
2. **Akvorado** — open-source flow collector and visualization platform, used in production by large ISPs and enterprises.
3. **Standard Linux VM** running Docker — the observability collector.

Data path:

```
AHV host's OVS  ─sFlow─>  Akvorado Inlet  ─Kafka─>  Akvorado Outlet  ─>  ClickHouse  ─>  Akvorado Console (UI)
```

That's it. Three components, one protocol, one storage engine.

---

## Why sFlow (and Not NetFlow)

Both protocols can produce flow records, and both run on AHV's OVS. We deliberately chose sFlow. Here's the comparison:

| Capability | NetFlow on AHV | sFlow on OVS |
|------------|----------------|--------------|
| Coverage | Every flow recorded (unsampled) | 1-in-N packets sampled |
| Byte/packet counts | Exact | Estimated (sample × rate) |
| Per-packet header content | No | **Yes (up to 512 bytes captured)** |
| Real-time anomaly visibility | Delayed (flow expires first) | **Immediate (per-sample)** |
| Counter samples (interface stats) | No | **Yes (every N seconds)** |
| CPU/network overhead at scale | Higher | **Lower** |
| Short connections (DNS, ICMP, 1-packet) | Captured | Often missed at sampling 1024+ |
| Exact billing/accounting | Excellent | Statistical only |

For an **observability and forensics platform**, sFlow wins decisively:

- **Storm detection** — sFlow counter samples expose interface saturation within seconds. NetFlow only reveals a storm after flows expire.
- **Header capture** — sFlow's 512-byte header lets you inspect L4 flags, TCP options, and L7 protocol indicators without running a separate IDS.
- **Lower overhead** — sampled traffic means lower CPU on each AHV host. NetFlow on a busy cluster can consume noticeable CVM CPU.
- **Consistent semantics for AI/ML** — A single sampling-based source is easier to model and reason about than mixed sampled+unsampled telemetry.

The tradeoff: you lose visibility into very short connections (DNS lookups, single-packet probes). If compliance (PCI-DSS audit trails, SOX) requires unsampled flow records, run NetFlow as a parallel stream for the compliance archive — separate from the observability pipeline.

---

## Why Multi-Bridge OVS Attach

This is the single biggest design lesson from building the platform. **Attaching sFlow to a single bridge captures only a fraction of VM traffic.**

A typical Nutanix AHV host has many OVS bridges, each serving a different purpose:

| Bridge | Purpose | Has VM taps? |
|--------|---------|--------------|
| `br0` | Primary external bridge | Yes (vnet/tap interfaces) |
| `br0.local` | Local intra-host bridge | Yes |
| `brAtlas` | Atlas overlay (Flow Networking) | Yes |
| `br1`, `br1.local` | Secondary uplinks | Sometimes |
| `brSpan` | SPAN/mirror destination | No |
| `br.nf`, `br.mx`, `br.microseg`, `br.dmx` | Internal/system | No |

If you attach sFlow only to `br0`, you see external traffic but miss intra-host VM communication on `br0.local`. If you skip `brAtlas`, you miss all traffic going through Flow Networking overlays.

**The pattern that works:** attach the same sFlow configuration to all VM-bearing bridges (`br0`, `br0.local`, `brAtlas`, plus `br1` and `br1.local` if they exist on your hosts). Single transaction:

```bash
ovs-vsctl -- --id=@sf create sflow targets='[...]' header=512 sampling=1024 polling=20 \
  -- set bridge br0 sflow=@sf \
  -- set bridge br0.local sflow=@sf \
  -- set bridge brAtlas sflow=@sf
```

Skip bridges that have no VM taps — they generate counter samples with no value.

---

## Why Akvorado

Several open-source flow collectors exist (ntopng, GoFlow2, nfsen, pmacct, FastNetMon, ElastiFlow). Akvorado was selected because:

1. **Production-tested at scale** — used by ISPs handling 100M+ flows per second.
2. **Modular architecture** — inlet, outlet, and console as separate services. Each can be scaled and operated independently.
3. **Native protocol support** — sFlow v5, NetFlow v5/v9, IPFIX, all out of the box.
4. **ClickHouse backend** — column-oriented storage scales horizontally and queries time-series data efficiently.
5. **Kafka buffer** — decouples ingestion from storage. If ClickHouse is slow or down, Kafka holds the data.
6. **Schema enrichment** — built-in support for ASN lookups, GeoIP, and custom metadata via Akvorado's static or SNMP providers.
7. **Active development** — maintained, responsive maintainers, real-world deployments driving improvements.
8. **AGPL-3.0 license** — guarantees the project remains open.

For our use case (multi-cluster Nutanix observability with DR awareness), Akvorado's built-in support for exporter-level metadata fields (`name`, `group`, `role`, `site`, `region`, `tenant`) is particularly valuable.

---

## Why ClickHouse

Akvorado bundles ClickHouse, but it's worth understanding why:

- **Column-oriented storage** — flow records are mostly numeric and have many columns; column-oriented compression is dramatic.
- **Fast aggregations** — `GROUP BY ExporterAddress, count()` over millions of rows in milliseconds.
- **Materialized views** — Akvorado uses these to pre-aggregate data at different time resolutions (5-min, hourly, daily) for efficient long-term queries.
- **SQL** — analysts can query directly without learning a custom query language.

A single ClickHouse node on commodity hardware (32 GB RAM, NVMe storage) handles 50,000+ flows/second sustained. For larger estates, ClickHouse clusters horizontally.

---

## The DR-Aware Metadata Schema

A naive deployment treats every AHV cluster as an isolated exporter. That works for a single site but becomes unmanageable across multiple datacenters. Our schema encodes the relationships that matter:

| Metadata field | Purpose | Example |
|----------------|---------|---------|
| `name` | Cluster identifier | `dc15-cl01-ahv` |
| `group` | Datacenter + environment | `dc15-lab`, `dc15-prod` |
| `role` | Environment tier | `lab`, `dev`, `staging`, `prod` |
| `site` | Physical datacenter | `dc15`, `dc16` |
| `region` | **DR pair identifier** | `dr-pair-01`, `dr-pair-02` |
| `tenant` | Business unit | `infra`, `customer-a` |

The most important field is `region`, which we use to denote **DR pair relationships** rather than geography. Two clusters mirrored for disaster recovery share the same `region` value. This gives you free DR-aware queries:

- "Show all traffic in DR Pair 01" → `ExporterRegion = "dr-pair-01"`
- "Compare primary vs DR within Pair 01" → group by `ExporterSite` filtered by region
- "Cross-site replication volumes" → src/dst on opposite sites within same region

See [`05-naming-convention.md`](05-naming-convention.md) for the full schema and expansion patterns.

---

## What This Architecture Does NOT Solve

Be honest about scope:

- **L7 protocol decoding** — sFlow's 512-byte header captures TCP flags and L4 ports but not application-layer semantics. For HTTP/DNS/TLS parsing, integrate Suricata or Zeek on the same hosts.
- **Endpoint identity** — flow records identify IP addresses, not users or applications. Combine with directory data (LDAP/AD) externally.
- **Encrypted traffic content** — header capture shows that encrypted traffic exists, not what it contains. This is by design and a feature, not a limitation.
- **Real-time line-rate analysis** — sFlow is sampled. For 100% capture at line rate, use SPAN/mirror ports to a dedicated capture appliance. That's a different problem.

---

## Performance Notes

Empirical observations from a lab deployment with **~15 AHV hosts across two DR-paired sites** and **~150 VMs total**:

- **sFlow at 1024 sampling, 512-byte header, 20s polling**: ~3 MB/s aggregate sFlow datagrams to the collector
- **Akvorado inlet CPU**: < 15% of a single core
- **Kafka throughput**: ~150 KB/s sustained, well within single-broker capacity
- **ClickHouse insert rate**: 50,000–80,000 rows/minute
- **Query latency**: 5-minute aggregations return in < 200 ms

For larger estates (100+ AHV hosts, 1000+ VMs), increase sampling rate to 2048 or 4096, scale Akvorado inlets horizontally, and consider a multi-node ClickHouse cluster. The architecture supports this; the same configuration patterns apply.

---

## Next Steps

- [`02-installation.md`](02-installation.md) — set up the observability VM from scratch
- [`03-ahv-sflow-configuration.md`](03-ahv-sflow-configuration.md) — configure sFlow on AHV hosts
- [`04-akvorado-configuration.md`](04-akvorado-configuration.md) — Akvorado config files explained
- [`05-naming-convention.md`](05-naming-convention.md) — DR-aware metadata schema in detail
- [`06-troubleshooting.md`](06-troubleshooting.md) — common issues and how to diagnose them
