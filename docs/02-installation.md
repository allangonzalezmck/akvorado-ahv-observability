# 02 — Installation Guide

A step-by-step walkthrough from a bare Linux VM to a working Akvorado deployment receiving sFlow from your AHV hosts.

This guide assumes:

- You have admin access to a Linux VM that will host the collector
- The VM has network reachability to your AHV cluster management subnet
- You have SSH/root access to at least one AHV host for the initial pilot

---

## 1. Collector VM Specifications

### Minimum (Lab / Small Pilot)

| Resource | Spec |
|----------|------|
| OS | Ubuntu 24.04 LTS or later (Debian 12+ also works) |
| vCPU | 8 cores |
| RAM | 32 GB |
| Disk | 500 GB (fast tier for ClickHouse) |
| Network | 1 Gbps |

### Recommended (Production, 10–50 AHV hosts)

| Resource | Spec |
|----------|------|
| OS | Ubuntu 24.04 LTS |
| vCPU | 16–32 cores (NUMA-aware placement helps) |
| RAM | 64–128 GB |
| Disk | 2 TB NVMe for ClickHouse + 1 TB for Kafka |
| Network | 10 Gbps |

### At Scale (100+ AHV hosts, multiple DCs)

Run inlet, outlet, Kafka, and ClickHouse on separate VMs or as a cluster. The Akvorado documentation covers HA topologies in detail.

---

## 2. Prepare the VM

### 2.1 OS-level tuning

UDP buffers must be large enough to absorb bursts of sFlow datagrams:

```bash
sudo tee /etc/sysctl.d/99-akvorado.conf <<EOF
net.core.rmem_max = 268435456
net.core.rmem_default = 16777216
net.core.netdev_max_backlog = 30000
EOF

sudo sysctl --system
```

### 2.2 Firewall

Open the necessary ports. If you use `ufw`:

```bash
sudo ufw allow 22/tcp     comment 'SSH'
sudo ufw allow 6343/udp   comment 'sFlow default'
sudo ufw allow 6344/udp   comment 'sFlow (Akvorado mapped port)'
sudo ufw allow 2055/udp   comment 'NetFlow (optional)'
sudo ufw allow 4739/udp   comment 'IPFIX (optional)'
sudo ufw allow 8080/tcp   comment 'Akvorado console'
sudo ufw enable
```

### 2.3 Storage layout

ClickHouse benefits significantly from a dedicated fast disk. Recommended mount layout:

```
/srv/fast       — NVMe or SSD, mounted for /srv/fast/clickhouse and /srv/fast/kafka
/srv/bulk       — HDD or larger SSD, for backups and overflow
```

Create the directories:

```bash
sudo mkdir -p /srv/fast/clickhouse /srv/fast/kafka /srv/fast/docker-volumes
sudo chown -R $USER:$USER /srv/fast
```

---

## 3. Install Docker

Use the official Docker repository (not the distribution's package — version too old):

```bash
# Remove any old version
sudo apt remove -y docker docker-engine docker.io containerd runc

# Install prerequisites
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add your user to the docker group
sudo usermod -aG docker $USER
newgrp docker

# Verify
docker --version
docker compose version
```

### 3.1 (Optional) Move Docker data to fast storage

```bash
sudo systemctl stop docker
sudo tee /etc/docker/daemon.json <<EOF
{
  "data-root": "/srv/fast/docker-volumes"
}
EOF
sudo systemctl start docker
```

---

## 4. Deploy Akvorado

### 4.1 Clone Akvorado

```bash
sudo mkdir -p /srv/fast/workspace
sudo chown $USER:$USER /srv/fast/workspace
cd /srv/fast/workspace

git clone https://github.com/akvorado/akvorado.git
cd akvorado
```

### 4.2 Apply this repository's configuration templates

```bash
# Replace <PATH_TO_THIS_REPO> with the path to this repository on your system
cp <PATH_TO_THIS_REPO>/config/akvorado.yaml.example          config/akvorado.yaml
cp <PATH_TO_THIS_REPO>/config/inlet.yaml.example             config/inlet.yaml
cp <PATH_TO_THIS_REPO>/config/docker-compose.override.yml.example  docker/docker-compose.override.yml
```

### 4.3 Edit `akvorado.yaml`

Open `config/akvorado.yaml` and replace the placeholders. Specifically:

- Replace `192.0.2.0/24` and `198.51.100.0/24` with your actual AHV cluster management subnets.
- Adjust `name`, `group`, `site`, `region`, `tenant` fields to match your conventions.
- See [`05-naming-convention.md`](05-naming-convention.md) for the schema.

### 4.4 Edit the `.env` file (if needed)

The Akvorado `docker/` directory includes a `.env` file that controls default platform. If you encounter "manifest unknown" errors on ARM/multi-arch hosts:

```bash
echo 'DOCKER_DEFAULT_PLATFORM=linux/amd64' > docker/.env
```

### 4.5 Validate config before starting

```bash
cd /srv/fast/workspace/akvorado/docker
docker compose run --rm akvorado-orchestrator orchestrator /etc/akvorado/akvorado.yaml --check 2>&1 | tail -20
```

If you see "invalid keys" or parse errors, fix them before proceeding.

### 4.6 Start the stack

```bash
docker compose up -d
```

### 4.7 Verify all containers are healthy

```bash
docker compose ps
```

All services should show `Up` and `(healthy)`. If any are restarting or unhealthy, inspect logs:

```bash
docker logs docker-akvorado-orchestrator-1 --tail 30
docker logs docker-akvorado-inlet-1 --tail 30
docker logs docker-akvorado-outlet-1 --tail 30
```

---

## 5. Configure sFlow on AHV Hosts

See [`03-ahv-sflow-configuration.md`](03-ahv-sflow-configuration.md) for the full procedure. Quick version:

```bash
# Run on each AHV host as root
ovs-vsctl -- --id=@sf create sflow \
  targets='["<YOUR_COLLECTOR_IP>:6344"]' \
  header=512 \
  sampling=1024 \
  polling=20 \
  -- set bridge br0 sflow=@sf \
  -- set bridge br0.local sflow=@sf \
  -- set bridge brAtlas sflow=@sf
```

Replace `<YOUR_COLLECTOR_IP>` with the IP of your collector VM.

---

## 6. Verify End-to-End

### 6.1 Confirm packets arriving at the collector

```bash
# On the collector VM
sudo tcpdump -nn -i any -c 50 'udp port 6344'
```

You should see sFlow datagrams arriving from your AHV hosts within seconds.

### 6.2 Confirm Akvorado is decoding them

```bash
docker exec docker-clickhouse-1 clickhouse-client --query "
SELECT
  IPv6NumToString(ExporterAddress) AS exporter,
  count() AS flows,
  uniq(SrcAddr) AS unique_src_ips,
  max(TimeReceived) AS latest
FROM flows
WHERE TimeReceived > now() - INTERVAL 2 MINUTE
GROUP BY exporter
ORDER BY exporter"
```

Within a minute, each configured AHV host should appear as an exporter with flow counts.

### 6.3 Open the Akvorado UI

In a browser:

```
http://<YOUR_COLLECTOR_IP>:8080
```

Click **Visualize**. Set:

- **Time range:** last 30 minutes
- **Dimensions:** `ExporterAddress` (or `ExporterName` for friendly labels)
- **Limit:** 20

Click **Refresh**. You should see traffic broken down by AHV host.

---

## 7. Roll Out to All AHV Hosts

Once one host is validated, deploy the sFlow configuration to all hosts using your preferred automation:

### Ad-hoc shell loop

```bash
# From a jump host that can SSH to all AHV hosts
AHV_HOSTS=(<host-1> <host-2> <host-3> ...)

for host in "${AHV_HOSTS[@]}"; do
  echo "=== ${host} ==="
  ssh root@${host} 'ovs-vsctl -- --id=@sf create sflow \
    targets="[\"<YOUR_COLLECTOR_IP>:6344\"]" \
    header=512 sampling=1024 polling=20 \
    -- set bridge br0 sflow=@sf \
    -- set bridge br0.local sflow=@sf \
    -- set bridge brAtlas sflow=@sf'
done
```

### Ansible

Define an inventory of AHV hosts and use the `community.general.openvswitch_*` modules, or wrap the shell loop above in an `ansible.builtin.shell` task.

### Verification after rollout

```bash
docker exec docker-clickhouse-1 clickhouse-client --query "
SELECT
  IPv6NumToString(ExporterAddress) AS exporter,
  count() AS flows
FROM flows
WHERE TimeReceived > now() - INTERVAL 2 MINUTE
GROUP BY exporter
ORDER BY exporter"
```

All your AHV hosts should appear.

---

## 8. Common Post-Install Tasks

### Reload Akvorado after config changes

Whenever you edit `akvorado.yaml`:

```bash
cd /srv/fast/workspace/akvorado/docker

# Validate first
docker compose run --rm akvorado-orchestrator orchestrator /etc/akvorado/akvorado.yaml --check 2>&1 | tail -20

# Restart the components that consume the config
docker compose restart akvorado-orchestrator akvorado-outlet
```

### Backup ClickHouse

For production, schedule regular ClickHouse backups using `clickhouse-backup` or filesystem snapshots of `/srv/fast/clickhouse`.

### Monitor the collector itself

Akvorado exposes Prometheus metrics on each component:

- Inlet: `http://<inlet-container-ip>:8080/api/v0/inlet/metrics`
- Outlet: `http://<outlet-container-ip>:8080/api/v0/outlet/metrics`

Scrape these from your monitoring system.

---

## 9. What to Do If Something Doesn't Work

See [`06-troubleshooting.md`](06-troubleshooting.md). It documents the issues we hit in our own buildout, including:

- "Flows appear in inlet metrics but not in ClickHouse" → outlet metadata gap
- "Only counter samples, no flow samples" → OVS sampling rate set to 0
- "YAML parse errors" → Akvorado's `!include` tag handling
- "Containers crash-loop on startup" → invalid config schema (e.g., extra keys)

---

## 10. Next Reading

- [`03-ahv-sflow-configuration.md`](03-ahv-sflow-configuration.md) — OVS sFlow setup details
- [`04-akvorado-configuration.md`](04-akvorado-configuration.md) — every config file explained
- [`05-naming-convention.md`](05-naming-convention.md) — DR-aware metadata schema
