# 05 — DR-Aware Metadata Naming Convention

This document describes a metadata schema for labeling AHV clusters in a multi-site, multi-environment estate. The schema is designed to:

- Scale from a single lab to dozens of clusters across multiple datacenters
- Encode DR pair relationships natively so cross-site queries are trivial
- Stay readable and predictable as new clusters are onboarded
- Enable powerful Akvorado UI filtering without ad-hoc dimensions

If you're running a single-cluster lab, you don't need all of this. But adopting the schema early saves significant rework when the estate grows.

---

## The Six Metadata Fields

Akvorado's static metadata provider supports these per-exporter fields:

| Field | Purpose | Example values |
|-------|---------|----------------|
| `name` | Cluster identifier | `dc01-cl01-ahv`, `site-a-cl02-ahv` |
| `group` | Datacenter + environment binding | `dc01-lab`, `dc01-prod`, `site-a-dev` |
| `role` | Environment tier | `lab`, `dev`, `staging`, `prod` |
| `site` | Physical datacenter or location | `dc01`, `dc02`, `site-a`, `site-b` |
| `region` | **DR pair identifier** (not geography) | `dr-pair-01`, `dr-pair-02` |
| `tenant` | Business unit or customer | `infra`, `customer-a`, `analytics` |

The non-obvious decision is **using `region` for DR pairs**, not geographic regions. Geographic location is captured by `site`. The `region` field is repurposed because it gives you a free dimension to express the DR relationship — two clusters DR-paired with each other share the same `region` value.

---

## Naming Convention

### `name` — Cluster identifier

Format: `<site>-<cluster>-<platform>`

Examples:
- `dc01-cl01-ahv` — Cluster 1 at DC01, AHV platform
- `dc01-cl02-ahv` — Cluster 2 at DC01
- `dc02-cl01-ahv` — Cluster 1 at DC02 (typically DR-paired with `dc01-cl01-ahv` if DC02 is DC01's DR site)

**Cluster numbering** is per-site: `cl01`, `cl02`, `cl03`. Each datacenter starts its own count.

**Why per-site numbering?** It mirrors how operations teams refer to clusters internally. `dc01-cl01` and `dc02-cl01` being primary-and-DR pair is intuitive. Global numbering (cl01, cl02 across all datacenters) doesn't preserve the relationship.

### `group` — Datacenter + environment binding

Format: `<site>-<environment>`

Examples:
- `dc01-lab` — All lab clusters at DC01
- `dc01-prod` — All prod clusters at DC01
- `dc02-staging` — All staging clusters at DC02

`group` is what you'd use to answer "show me all production traffic at DC01."

### `role` — Environment tier

Single word from a controlled vocabulary:

- `lab` — non-production, freely modifiable
- `dev` — developer-shared, may have customer-like data
- `staging` — pre-production, mirrors prod config
- `prod` — production, live customer traffic
- `unknown` — for the catchall

`role` is the dimension to filter on for environment-wide queries: "show all lab traffic regardless of DC."

### `site` — Physical datacenter

A short code identifying the physical datacenter. Examples: `dc01`, `dc02`, `site-a`, `cloud-east`, `colo-fra02`.

Avoid embedding environment information here — `site` should be stable across environment changes.

### `region` — DR pair identifier

Format: `dr-pair-<NN>` where NN is a two-digit number.

Examples:
- `dr-pair-01` — first DR pair (e.g., DC01 LAB ↔ DC02 LAB)
- `dr-pair-02` — second DR pair (e.g., DC01 PROD ↔ DC02 PROD)
- `dr-pair-03` — third DR pair (e.g., DC03 PROD ↔ DC04 PROD)

**Each DR pair gets a unique number.** Two clusters that DR-mirror each other share the same `region` value.

For clusters with no DR pair (sandbox, one-off labs):

- `region: "standalone"` — explicit "no DR"

### `tenant` — Business unit / customer

A short identifier for the business unit, customer, or workload type. Examples:

- `infra` — infrastructure / shared services
- `customer-a` — Customer A workloads
- `customer-b` — Customer B workloads
- `analytics` — data analytics workloads
- `dev-shared` — shared developer workloads

---

## Complete Worked Example

A medium-size estate: 4 datacenters (DC01, DC02 are East Coast DR-paired; DC03, DC04 are West Coast DR-paired), 3 environments (lab, dev, prod), 2 customer tenants.

| Cluster | name | group | role | site | region | tenant |
|---------|------|-------|------|------|--------|--------|
| DC01 LAB Cluster 1 | `dc01-cl01-ahv` | `dc01-lab` | `lab` | `dc01` | `dr-pair-01` | `infra` |
| DC02 LAB Cluster 1 | `dc02-cl01-ahv` | `dc02-lab` | `lab` | `dc02` | `dr-pair-01` | `infra` |
| DC01 DEV Cluster 2 | `dc01-cl02-ahv` | `dc01-dev` | `dev` | `dc01` | `dr-pair-02` | `infra` |
| DC02 DEV Cluster 2 | `dc02-cl02-ahv` | `dc02-dev` | `dev` | `dc02` | `dr-pair-02` | `infra` |
| DC01 PROD Cluster 3 (Customer A) | `dc01-cl03-ahv` | `dc01-prod` | `prod` | `dc01` | `dr-pair-03` | `customer-a` |
| DC02 PROD Cluster 3 (Customer A) | `dc02-cl03-ahv` | `dc02-prod` | `prod` | `dc02` | `dr-pair-03` | `customer-a` |
| DC01 PROD Cluster 4 (Customer B) | `dc01-cl04-ahv` | `dc01-prod` | `prod` | `dc01` | `dr-pair-04` | `customer-b` |
| DC02 PROD Cluster 4 (Customer B) | `dc02-cl04-ahv` | `dc02-prod` | `prod` | `dc02` | `dr-pair-04` | `customer-b` |
| DC03 PROD Cluster 1 (Customer A) | `dc03-cl01-ahv` | `dc03-prod` | `prod` | `dc03` | `dr-pair-05` | `customer-a` |
| DC04 PROD Cluster 1 (Customer A) | `dc04-cl01-ahv` | `dc04-prod` | `prod` | `dc04` | `dr-pair-05` | `customer-a` |

10 clusters, 5 DR pairs, fully searchable along any dimension.

---

## What This Schema Lets You Do

Each of these is a single filter or dimension change in the Akvorado UI:

| Question | Filter / Dimension |
|----------|---------------------|
| All lab traffic | filter: `ExporterRole = "lab"` |
| All DC01 traffic, all environments | filter: `ExporterSite = "dc01"` |
| All Customer A traffic, any DC, any environment | filter: `ExporterTenant = "customer-a"` |
| Compare lab vs prod side-by-side | dimension: `ExporterRole` |
| Per-DC traffic volumes | dimension: `ExporterSite` |
| Per-cluster breakdown | dimension: `ExporterName` |
| Per-host detail within a cluster | dimension: `ExporterAddress` |
| All traffic in DR Pair 03 (DC01-CL03 + DC02-CL03) | filter: `ExporterRegion = "dr-pair-03"` |
| Compare primary vs DR within Pair 03 | filter: `ExporterRegion = "dr-pair-03"`, dim: `ExporterSite` |
| Cross-site DR replication traffic for Pair 03 | filter: `ExporterRegion = "dr-pair-03"` AND `SrcAddr` and `DstAddr` on opposite sites |

The last one is particularly useful — it shows you the actual replication / failover traffic moving between paired DCs. Useful for:

- Baselining normal DR replication volumes
- Detecting unusual cross-site flows (potential lateral movement)
- Validating DR drill execution

---

## Configuration Template

Here is the corresponding `outlet:` block in `akvorado.yaml` for the worked example. Adjust the CIDRs to match your actual AHV management subnets:

```yaml
outlet:
  metadata:
    providers:
      - type: static
        exporters:
          # ==========================================
          # DR Pair 01 — LAB clusters
          # DC01-CL01 <-> DC02-CL01
          # ==========================================

          "10.10.0.0/24":
            name: "dc01-cl01-ahv"
            group: "dc01-lab"
            role: "lab"
            site: "dc01"
            region: "dr-pair-01"
            tenant: "infra"
            default: { name: "unknown", description: "unknown", speed: 10000 }

          "10.20.0.0/24":
            name: "dc02-cl01-ahv"
            group: "dc02-lab"
            role: "lab"
            site: "dc02"
            region: "dr-pair-01"
            tenant: "infra"
            default: { name: "unknown", description: "unknown", speed: 10000 }

          # ==========================================
          # DR Pair 02 — DEV clusters
          # DC01-CL02 <-> DC02-CL02
          # ==========================================

          "10.11.0.0/24":
            name: "dc01-cl02-ahv"
            group: "dc01-dev"
            role: "dev"
            site: "dc01"
            region: "dr-pair-02"
            tenant: "infra"
            default: { name: "unknown", description: "unknown", speed: 10000 }

          "10.21.0.0/24":
            name: "dc02-cl02-ahv"
            group: "dc02-dev"
            role: "dev"
            site: "dc02"
            region: "dr-pair-02"
            tenant: "infra"
            default: { name: "unknown", description: "unknown", speed: 10000 }

          # ==========================================
          # DR Pair 03 — PROD clusters, Customer A
          # DC01-CL03 <-> DC02-CL03
          # ==========================================

          "10.12.0.0/24":
            name: "dc01-cl03-ahv"
            group: "dc01-prod"
            role: "prod"
            site: "dc01"
            region: "dr-pair-03"
            tenant: "customer-a"
            default: { name: "unknown", description: "unknown", speed: 10000 }

          "10.22.0.0/24":
            name: "dc02-cl03-ahv"
            group: "dc02-prod"
            role: "prod"
            site: "dc02"
            region: "dr-pair-03"
            tenant: "customer-a"
            default: { name: "unknown", description: "unknown", speed: 10000 }

          # ==========================================
          # Catchall — unconfigured exporters
          # Must remain LAST and matches anything not above.
          # Prevents flows from being silently dropped at the outlet.
          # ==========================================

          "0.0.0.0/0":
            name: "unclassified-exporter"
            group: "unclassified"
            role: "unknown"
            site: "unknown"
            region: "unknown"
            tenant: "unknown"
            default: { name: "unknown", description: "unknown", speed: 10000 }

          "::/0":
            name: "unclassified-exporter"
            group: "unclassified"
            role: "unknown"
            site: "unknown"
            region: "unknown"
            tenant: "unknown"
            default: { name: "unknown", description: "unknown", speed: 10000 }
```

---

## Important Behavioral Notes

### CIDR matching is most-specific-wins

If an exporter IP matches multiple CIDRs, Akvorado uses the most specific. The catchall `0.0.0.0/0` is matched only if no more-specific entry matches.

### The catchall is mandatory

Without `0.0.0.0/0` (and `::/0` for IPv6), any exporter not explicitly listed will have its flows silently dropped at the outlet's metadata enrichment stage. We learned this the hard way.

### Per-host /32 entries are usually wrong

It's tempting to give each host its own /32 entry for granular naming. Don't. Akvorado already provides per-host visibility through the `ExporterAddress` dimension. Per-host metadata becomes a maintenance burden at scale.

The exception: if a single AHV host has a fundamentally different role than its cluster siblings (testing, isolation, special-purpose), a /32 entry can be justified.

### Description fields belong in comments

Akvorado does NOT support a top-level `description` field on exporter entries. (It exists only inside the `default:` block for interfaces.) Use YAML comments for human-readable context about each entry — they're visible to operators reading the file but ignored by Akvorado.

### Configuration is reloadable

Changes to this block take effect after restarting `akvorado-orchestrator` and `akvorado-outlet`:

```bash
docker compose restart akvorado-orchestrator akvorado-outlet
```

No data loss or downtime — in-flight Kafka messages continue processing.

---

## Future: IPAM Integration

For very large estates with hundreds of clusters and thousands of subnets, manually maintaining this YAML becomes impractical. The right long-term path is to source this metadata from an IPAM system (Infoblox, NetBox, BlueCat, phpIPAM).

Akvorado supports this via the `network-sources` configuration in the `clickhouse.networks` block — see the Akvorado documentation. The same pattern can be applied to outlet exporter metadata via a custom provider.

For now, the static configuration is the recommended approach because it's reviewable, version-controllable (commit `akvorado.yaml` to Git), and operationally simple.
