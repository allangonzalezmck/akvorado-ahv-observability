#!/bin/bash
# ============================================================================
# AHV sFlow Setup — Idempotent Open vSwitch Configuration
# ============================================================================
#
# Configures sFlow on a Nutanix AHV host's Open vSwitch instance.
# Attaches the same sFlow record to all VM-bearing bridges.
#
# Safe to re-run — removes any existing sFlow/NetFlow first, then reapplies.
#
# Usage:
#   1. Edit the CONFIGURATION section below to match your environment
#   2. Copy this script to each AHV host as /root/ahv-sflow-setup.sh
#   3. Run as root: bash /root/ahv-sflow-setup.sh
#
# Documentation: ../docs/03-ahv-sflow-configuration.md
# ============================================================================

set -e

# =============================================================================
# CONFIGURATION — edit these for your environment
# =============================================================================

COLLECTOR_IP="10.0.0.10"        # ← REPLACE with your collector VM IP
COLLECTOR_PORT="6344"           # Akvorado inlet sFlow port (host side)
SAMPLING_RATE="1024"            # 1-in-N packet sampling
POLLING_INTERVAL="20"           # Counter sample interval (seconds)
HEADER_BYTES="512"              # Per-sample header capture size

# VM-bearing bridges. Edit if your AHV bridge names differ.
# Bridges that don't exist on a given host are silently skipped.
TARGET_BRIDGES=("br0" "br0.local" "brAtlas" "br1" "br1.local")

# =============================================================================
# Script logic — typically no need to edit below this line
# =============================================================================

echo "================================================================"
echo "AHV sFlow Setup on $(hostname)"
echo "Collector:  ${COLLECTOR_IP}:${COLLECTOR_PORT}"
echo "Sampling:   1-in-${SAMPLING_RATE}"
echo "Polling:    ${POLLING_INTERVAL}s"
echo "Header:     ${HEADER_BYTES} bytes"
echo "================================================================"
echo ""

# Sanity check — require root
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# Sanity check — require ovs-vsctl
if ! command -v ovs-vsctl > /dev/null; then
    echo "ERROR: ovs-vsctl not found. Is this an AHV host?"
    exit 1
fi

# ---- STEP 1: Remove any existing NetFlow config ----
echo "[1/4] Removing existing NetFlow config (if any)..."
for br in $(ovs-vsctl list-br); do
    ovs-vsctl clear bridge $br netflow 2>/dev/null || true
done
for nf_uuid in $(ovs-vsctl --columns=_uuid find netflow 2>/dev/null | awk '/_uuid/{print $3}'); do
    ovs-vsctl destroy netflow $nf_uuid 2>/dev/null || true
done
echo "      Done."

# ---- STEP 2: Remove existing sFlow config ----
echo "[2/4] Removing existing sFlow config (if any)..."
for br in $(ovs-vsctl list-br); do
    ovs-vsctl clear bridge $br sflow 2>/dev/null || true
done
for sf_uuid in $(ovs-vsctl --columns=_uuid find sflow 2>/dev/null | awk '/_uuid/{print $3}'); do
    ovs-vsctl destroy sflow $sf_uuid 2>/dev/null || true
done
echo "      Done."

# ---- STEP 3: Create new sFlow record ----
echo "[3/4] Creating new sFlow record..."
SFLOW_UUID=$(ovs-vsctl -- --id=@sf create sflow \
    targets="[\"${COLLECTOR_IP}:${COLLECTOR_PORT}\"]" \
    header=${HEADER_BYTES} \
    sampling=${SAMPLING_RATE} \
    polling=${POLLING_INTERVAL})
echo "      Created sFlow UUID: ${SFLOW_UUID}"

# ---- STEP 4: Attach to VM-bearing bridges ----
echo "[4/4] Attaching sFlow to VM-bearing bridges..."
attached_count=0
for br in "${TARGET_BRIDGES[@]}"; do
    if ovs-vsctl list-br | grep -qx "${br}"; then
        ovs-vsctl set bridge ${br} sflow=${SFLOW_UUID}
        port_count=$(ovs-vsctl list-ports ${br} | wc -l)
        echo "      OK  ${br} (${port_count} ports)"
        attached_count=$((attached_count + 1))
    else
        echo "      --  ${br} (not present on this host, skipped)"
    fi
done

if [ ${attached_count} -eq 0 ]; then
    echo ""
    echo "WARNING: No target bridges were found on this host."
    echo "         Verify TARGET_BRIDGES matches the bridges on this host:"
    echo "         $(ovs-vsctl list-br)"
fi

# ---- Verification ----
echo ""
echo "================================================================"
echo "Verification"
echo "================================================================"
ovs-vsctl list sflow
echo ""
echo "Bridge attachments:"
for br in $(ovs-vsctl list-br); do
    sflow_id=$(ovs-vsctl get bridge $br sflow 2>/dev/null)
    if [ "$sflow_id" != "[]" ] && [ -n "$sflow_id" ]; then
        port_count=$(ovs-vsctl list-ports $br | wc -l)
        echo "   $br ($port_count ports)  ->  sflow=$sflow_id"
    fi
done

echo ""
echo "================================================================"
echo "Setup complete."
echo "================================================================"
echo ""
echo "Next steps:"
echo "  1. Verify packets reach the collector:"
echo "     On the collector: sudo tcpdump -nn -i any 'udp port ${COLLECTOR_PORT}'"
echo ""
echo "  2. Verify flows appear in ClickHouse (after ~30 seconds):"
echo "     On the collector:"
echo "     docker exec docker-clickhouse-1 clickhouse-client --query \\"
echo "       \"SELECT IPv6NumToString(ExporterAddress), count() FROM flows \\"
echo "        WHERE TimeReceived > now() - INTERVAL 2 MINUTE GROUP BY 1\""
