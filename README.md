# Akvorado for Nutanix AHV — Open Flow Observability

> A complete, production-grade observability stack for **Nutanix AHV** clusters using **Akvorado**, **sFlow**, and **Open vSwitch** — bringing east-west VM flow visibility to a platform that lacks it natively.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Nutanix AHV](https://img.shields.io/badge/Nutanix-AHV-orange.svg)](https://www.nutanix.com/)
[![Akvorado](https://img.shields.io/badge/Akvorado-2.x-green.svg)](https://github.com/akvorado/akvorado)

---

## Why This Project Exists

Nutanix AHV ships with limited per-flow visibility into VM-to-VM traffic. Flow Networking (Microseg) provides policy-level information, but operations teams responsible for incident response, capacity planning, traffic storm investigation, and DR validation typically have to rely on:

- Coarse CVM-level counters from Prism
- Manual `tcpdump` on individual hosts during incidents
- Commercial NDR products costing $80K–$500K+ per cluster

This project demonstrates a **fully open-source, on-premises alternative** that delivers:

- **Per-VM east-west flow visibility** via sFlow on OVS bridges
- **Sub-minute traffic storm detection** through interface counter samples
- **Forensic-grade packet header capture** (first 512 bytes per sample)
- **DR-aware metadata schema** for multi-site observability
- **No SaaS dependency** — entirely on-premises, no data leaves your network

Built on Akvorado, the data plane scales to many datacenters and hundreds of clusters on commodity hardware.

---

## Architecture at a Glance

```
┌─────────────────────────────────────────────────────────────┐
│                    Nutanix AHV Cluster                       │
│                                                              │
│   ┌──────────┐   ┌──────────┐   ┌──────────┐                 │
│   │  AHV-01  │   │  AHV-02  │   │  AHV-NN  │   (N hosts)     │
│   │          │   │          │   │          │                 │
│   │   OVS    │   │   OVS    │   │   OVS    │                 │
│   │   sFlow  │   │   sFlow  │   │   sFlow  │                 │
│   └────┬─────┘   └────┬─────┘   └────┬─────┘                 │
│        │              │              │                       │
│        └──────────────┴──────────────┘                       │
│                       │ sFlow datagrams (UDP/6343)           │
└───────────────────────┼──────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                Observability VM (single host)                │
│                                                              │
│   ┌────────────┐    ┌─────────┐    ┌────────────┐            │
│   │ Akvorado   │───>│  Kafka  │───>│ Akvorado   │            │
│   │   Inlet    │    │         │    │   Outlet   │            │
│   │ (decoder)  │    │         │    │ (enricher) │            │
│   └────────────┘    └─────────┘    └─────┬──────┘            │
│                                          │                   │
│                                          ▼                   │
│   ┌────────────┐                  ┌────────────┐             │
│   │  Console   │<─────────────────│ ClickHouse │             │
│   │   (UI)     │                  │  (storage) │             │
│   └────────────┘                  └────────────┘             │
└─────────────────────────────────────────────────────────────┘
```

Flows from every AHV host's OVS instance are sampled, captured (with full packet headers), shipped via Kafka, enriched with metadata (cluster name, DR pair, site, environment, tenant), stored in ClickHouse, and visualized through Akvorado's web UI.

---

## What's in This Repository

| Directory | Purpose |
|-----------|---------|
| [`docs/`](docs/) | Architecture, installation guide, configuration reference, troubleshooting |
| [`config/`](config/) | Sanitized Akvorado configuration templates (replace placeholders with your values) |
| [`scripts/`](scripts/) | OVS sFlow setup script for AHV hosts and ClickHouse verification queries |

### Documentation

| Document | What it covers |
|----------|----------------|
| [`01-architecture.md`](docs/01-architecture.md) | Why sFlow, why OVS multi-bridge attach, why Akvorado, data flow |
| [`02-installation.md`](docs/02-installation.md) | Step-by-step lab/production setup from bare VM to working UI |
| [`03-ahv-sflow-configuration.md`](docs/03-ahv-sflow-configuration.md) | OVS sFlow commands and the multi-bridge attach pattern |
| [`04-akvorado-configuration.md`](docs/04-akvorado-configuration.md) | Each config file explained, what each block does and why |
| [`05-naming-convention.md`](docs/05-naming-convention.md) | DR-aware metadata schema for multi-site, multi-environment estates |
| [`06-troubleshooting.md`](docs/06-troubleshooting.md) | Common pitfalls, including a few that took us days to figure out |

---

## Quick Start (5 Minutes to First Flow)

### Prerequisites

- A Linux VM with at least 8 vCPU, 32 GB RAM, 1 TB disk
- Docker CE + Docker Compose
- Network reachability from AHV hosts to the VM on UDP 6344
- SSH/admin access to at least one AHV host

### Deploy Akvorado

```bash
# 1. Clone Akvorado
git clone https://github.com/akvorado/akvorado.git
cd akvorado/docker

# 2. Apply the configs from this repo
cp /path/to/this/repo/config/akvorado.yaml.example          ../config/akvorado.yaml
cp /path/to/this/repo/config/inlet.yaml.example             ../config/inlet.yaml
cp /path/to/this/repo/config/docker-compose.override.yml.example  docker-compose.override.yml

# 3. Edit the placeholders in akvorado.yaml (subnets, names) and the .env file (if needed)

# 4. Start the stack
docker compose up -d

# 5. Verify all containers are healthy
docker compose ps
```

### Configure sFlow on AHV Hosts

On each AHV host as `root`:

```bash
ovs-vsctl -- --id=@sf create sflow \
  targets='["<YOUR_COLLECTOR_IP>:6344"]' \
  header=512 \
  sampling=1024 \
  polling=20 \
  -- set bridge br0 sflow=@sf \
  -- set bridge br0.local sflow=@sf \
  -- set bridge brAtlas sflow=@sf
```

Or use the [`scripts/ahv-sflow-setup.sh`](scripts/ahv-sflow-setup.sh) helper.

### Access the UI

Open `http://<your-collector-ip>:8080` in a browser. Within ~1 minute, flow records should appear in the Visualize tab.

---

## Key Design Decisions

This stack reflects several decisions made deliberately. They are documented in detail in [`docs/01-architecture.md`](docs/01-architecture.md), but in summary:

| Decision | Rationale |
|----------|-----------|
| sFlow over NetFlow | Lower CPU overhead, real-time, captures packet headers, better for storm detection |
| Multi-bridge OVS attach (`br0`, `br0.local`, `brAtlas`) | Each bridge sees a different slice of VM traffic — single-bridge attach misses 60–80% of east-west flows |
| Sampling rate 1024 | Balance between visibility on quiet VMs and inlet load at production scale |
| DR-aware metadata schema | Encode site, environment, tenant, and DR-pair relationships so a single dashboard answers questions across the whole estate |
| Akvorado over alternatives | Production-tested at large ISPs, native sFlow/NetFlow/IPFIX support, ClickHouse backend scales horizontally, clean separation of inlet/outlet for HA |
| No SaaS dependencies | All data stays on-premises — critical for regulated workloads (PCI, SOX, HIPAA) |

---

## What This Doesn't Do (Yet)

Honest scope:

- **No automatic anomaly detection.** This delivers visibility — what you build on top of it (alerting, ML, AIOps) is your call.
- **No agentless deep packet inspection.** sFlow header capture is 512 bytes; L7 protocol detection requires additional tooling (e.g., Suricata, Zeek).
- **No native integration with Nutanix Flow Networking policies.** You see traffic; you don't see policy decisions. Combining the two requires correlation work.
- **No automatic IPAM integration.** Subnet labeling is currently static. We recommend integrating with Infoblox or NetBox for production scale.

---

## Contributing

Pull requests, issues, and questions are welcome. This project exists because the community needed it — please help improve it.

Areas where contributions would be especially valuable:

- Integration recipes for Prometheus + Grafana on top of Akvorado metrics
- Anomaly detection pipelines (LangGraph + local LLMs over sFlow data)
- IPAM connector samples (Infoblox, NetBox, phpIPAM)
- Multi-region deployment patterns
- Performance benchmarks at scale

See [`CONTRIBUTING.md`](CONTRIBUTING.md) (to be added).

---

## License

This project is licensed under the [Apache License 2.0](LICENSE). Use it freely for commercial or non-commercial purposes.

Akvorado itself is licensed under AGPL-3.0 — that license applies to the Akvorado binary you deploy, not to this repository's configuration/documentation.

---

## Acknowledgments

- The [Akvorado project](https://github.com/akvorado/akvorado) and its maintainers — exceptional engineering.
- The Nutanix community for years of public discussion about AHV observability limitations.
- The Open vSwitch project — sFlow on OVS works beautifully when configured correctly.

---

## Disclaimer

This project is not affiliated with or endorsed by Nutanix, Inc., Akvorado, or any commercial entity. All trademarks belong to their respective owners. Use at your own risk; always test in a non-production environment first.
