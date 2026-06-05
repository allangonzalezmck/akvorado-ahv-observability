# 04 — Akvorado Configuration Reference

This document explains each Akvorado configuration file used in this stack, what each block does, and which values you typically need to change. All file paths assume the standard Akvorado clone layout (`config/` and `docker/` at the repository root).

---

## Configuration Files Overview

| File | Path | Purpose |
|------|------|---------|
| `akvorado.yaml` | `config/akvorado.yaml` | Master configuration. Contains Kafka, ClickHouse, GeoIP, and outlet metadata settings. References `inlet.yaml`. |
| `inlet.yaml` | `config/inlet.yaml` | sFlow/NetFlow/IPFIX listener configuration. |
| `docker-compose.override.yml` | `docker/docker-compose.override.yml` | Docker-level overrides: port mappings, volume binds. |
| `.env` | `docker/.env` | Environment variables (e.g., `DOCKER_DEFAULT_PLATFORM`). |

---

## 1. `akvorado.yaml`

### Kafka block

```yaml
kafka:
  topic: flows
  version: 3.3.1
  brokers:
    - kafka:9092
  topic-configuration:
    num-partitions: 8
    replication-factor: 1
    config-entries:
      segment.bytes: 1073741824
      retention.ms: 86400000
      cleanup.policy: delete
      compression.type: producer
```

**What it does:** Defines the Kafka topic Akvorado uses to buffer flow records between inlet and outlet.

**When to change:**

- `num-partitions: 8` — increase if you have many inlets (one inlet thread can read from one partition at a time).
- `replication-factor: 1` — single-broker Kafka. For HA, run a Kafka cluster and set replication-factor to 3.
- `retention.ms: 86400000` — 24 hours. The buffer between inlet and ClickHouse. If ClickHouse goes down, this is how long you have to recover before flows start dropping.

### GeoIP block

```yaml
geoip:
  optional: true
  asn-database:
    - /usr/share/GeoIP/asn.mmdb
  geo-database:
    - /usr/share/GeoIP/country.mmdb
```

**What it does:** Enriches flow records with ASN and country-of-origin information. Akvorado bundles IPinfo databases by default. For internal traffic only, the lookup returns "unknown" — that's fine, it's not used in east-west flow analysis anyway.

**When to change:** If you want MaxMind GeoIP2 instead of IPinfo, uncomment the relevant section. For purely internal observability, leave as-is.

### ClickHouse block

```yaml
clickhouse:
  orchestrator-url: http://akvorado-orchestrator:8080
  kafka:
    consumers: 4
  servers:
    - clickhouse:9000
  prometheus-endpoint: /metrics
  asns:
    64501: ACME Corporation
  networks:
    # SUBNET LABELING — left as RFC 5737 placeholders.
    # Optional. Leave the defaults if you're not labeling
    # subnets yet (see 05-naming-convention.md for why).
    192.0.2.0/24:
      name: ipv4-example
      role: example
  network-sources: []
```

**What it does:** Configures ClickHouse connectivity, Kafka consumers, and **optional** src/dst IP subnet labeling.

**Critical to understand:**

- The `networks` block is **purely cosmetic**. It labels SrcAddr and DstAddr with friendly names in the UI. **Flows are NOT dropped if a subnet isn't listed.**
- For production, integrate this with your IPAM (Infoblox, NetBox) rather than maintaining the YAML manually.
- The `asns` block adds friendly names for private ASN numbers. Optional.

### Inlet include

```yaml
inlet: !include "inlet.yaml"
```

**What it does:** Pulls in the inlet configuration from `inlet.yaml`. Keeps inlet config separated for readability. Akvorado's `!include` directive is custom YAML — standard YAML validators will complain about it; use Akvorado's own `--check` mode to validate.

### Outlet block (THE IMPORTANT ONE)

```yaml
outlet:
  metadata:
    providers:
      - type: static
        exporters:
          "<YOUR_AHV_SUBNET>/24":
            name: "..."
            group: "..."
            role: "..."
            site: "..."
            region: "..."
            tenant: "..."
            default:
              name: "unknown"
              description: "unknown"
              speed: 10000
          
          "0.0.0.0/0":
            name: "unclassified-exporter"
            ...
```

**What it does:** Tags each flow record with metadata about its source exporter (the AHV host that sent it).

**Critically important:** Unlike the `clickhouse.networks` block, the `outlet.metadata.providers.exporters` config **can cause flows to be dropped** if an exporter doesn't match any entry. This is why we always include a catchall `0.0.0.0/0` entry — to ensure that even unconfigured exporters get default metadata and aren't silently discarded.

**Valid fields per exporter entry:**

| Field | Type | Purpose |
|-------|------|---------|
| `name` | string | Cluster/exporter identifier |
| `group` | string | Logical grouping |
| `role` | string | Environment tier (lab, dev, prod) |
| `site` | string | Physical datacenter |
| `region` | string | DR pair or geographic region |
| `tenant` | string | Business unit / customer |
| `default` | object | Interface defaults (the only place `description` is a valid key) |
| `ifaces` | object | Per-interface mapping (advanced) |

**Note:** A top-level `description` field on the exporter is **not valid**. Put descriptive text in YAML comments instead.

See [`05-naming-convention.md`](05-naming-convention.md) for the full schema rationale and how to extend it for multi-site, multi-environment estates.

---

## 2. `inlet.yaml`

```yaml
---
kafka:
  brokers:
    - kafka:9092

flow:
  inputs:
    - type: udp
      decoder: netflow
      listen: ":2055"
      workers: 6
      receive-buffer: 10485760

    - type: udp
      decoder: sflow
      listen: ":6343"
      workers: 6
      receive-buffer: 10485760
```

**What it does:** Configures the UDP listeners for flow protocols. Each `inputs` entry creates a listener.

**Per-input settings:**

| Setting | Recommended | What it does |
|---------|-------------|--------------|
| `type` | `udp` | Listener protocol |
| `decoder` | `sflow` / `netflow` / `ipfix` | Flow protocol decoder |
| `listen` | `":6343"` for sFlow, `":2055"` for NetFlow | Listen address (inside container) |
| `workers` | `6` | Number of decoder threads |
| `receive-buffer` | `10485760` (10 MB) | UDP socket receive buffer size |

**When to change:**

- Comment out the NetFlow listener if you're sFlow-only (recommended for this stack — see architecture doc).
- Bump `workers` for very high-throughput inlets.
- Bump `receive-buffer` if you see `errors_total` increasing in inlet metrics.

---

## 3. `docker/docker-compose.override.yml`

```yaml
services:
  akvorado-inlet:
    ports:
      - "6344:6343/udp"
      - "2055:2055/udp"
      - "4739:4739/udp"

  akvorado-console:
    ports:
      - "8080:8080"

volumes:
  akvorado-clickhouse:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /srv/fast/clickhouse
  akvorado-kafka:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /srv/fast/kafka
```

**What it does:** Overrides the default Akvorado compose file with deployment-specific settings.

**Port mappings:**

- `6344:6343/udp` — host port 6344 → container port 6343. This is unusual but useful: it lets sFlow-RT (which uses 6343 by default) coexist with Akvorado on the same host without port conflicts. AHV hosts send sFlow to the collector on port 6344, which Docker NATs to container 6343 where Akvorado listens.
- `2055:2055/udp` — NetFlow.
- `4739:4739/udp` — IPFIX.
- `8080:8080` — Akvorado web UI.

**Volume binds:** Maps Docker volumes to specific directories on fast storage. Edit the `device:` paths to match your storage layout.

---

## 4. `.env`

```bash
DOCKER_DEFAULT_PLATFORM=linux/amd64
```

**What it does:** On multi-architecture hosts (ARM Macs, multi-arch CI systems), forces Docker to pull the x86_64 images Akvorado publishes. Most amd64 servers don't need this.

**Heads up:** The `.env` file location matters. Akvorado's `docker/` directory may include a `.env` placeholder that throws an error if you don't replace it. Ensure your `.env` is either valid or absent.

---

## Applying Configuration Changes

Any change to these files requires a reload of the affected Akvorado services:

```bash
cd /srv/fast/workspace/akvorado/docker

# Validate first
docker compose run --rm akvorado-orchestrator orchestrator /etc/akvorado/akvorado.yaml --check 2>&1 | tail -20

# Restart components that consume the config
docker compose restart akvorado-orchestrator akvorado-outlet

# If inlet.yaml or docker-compose.override.yml changed, also:
docker compose restart akvorado-inlet
docker compose restart akvorado-console
```

For full restart:

```bash
docker compose down
docker compose up -d
```

---

## Verification After Config Changes

```bash
# 1. All containers healthy
docker compose ps

# 2. Inlet receiving packets
INLET_IP=$(docker inspect docker-akvorado-inlet-1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
curl -s http://$INLET_IP:8080/api/v0/inlet/metrics | grep "akvorado_inlet_flow_input_udp_packets_total" | head

# 3. Flows in ClickHouse
docker exec docker-clickhouse-1 clickhouse-client --query "
SELECT count() FROM flows WHERE TimeReceived > now() - INTERVAL 1 MINUTE"

# 4. Metadata being applied
docker exec docker-clickhouse-1 clickhouse-client --query "
SELECT DISTINCT ExporterName, ExporterGroup, ExporterRole, ExporterSite, ExporterRegion
FROM flows WHERE TimeReceived > now() - INTERVAL 2 MINUTE
ORDER BY ExporterName"
```
