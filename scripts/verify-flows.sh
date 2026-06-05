#!/bin/bash
# ============================================================================
# ClickHouse Flow Verification Queries
# ============================================================================
#
# Quick health-check queries for the Akvorado flow database.
# Run on the collector VM after deploying sFlow on AHV hosts.
#
# Usage:
#   bash scripts/verify-flows.sh           # run all checks
#   bash scripts/verify-flows.sh exporters # run a specific check
#
# Documentation: ../docs/02-installation.md
# ============================================================================

set -e

CLICKHOUSE_CONTAINER="${CLICKHOUSE_CONTAINER:-docker-clickhouse-1}"

CHK="${1:-all}"

run_query() {
    local label="$1"
    local query="$2"
    echo ""
    echo "============================================================"
    echo "  ${label}"
    echo "============================================================"
    docker exec "${CLICKHOUSE_CONTAINER}" clickhouse-client --query "${query}"
}

# ---------------------------------------------------------------------------
# Check 1: Are there any flows in the last 5 minutes?
# ---------------------------------------------------------------------------
check_total() {
    run_query "Total flows in last 5 minutes" "
        SELECT
          count() AS total_flows,
          uniq(ExporterAddress) AS unique_exporters,
          min(TimeReceived) AS earliest,
          max(TimeReceived) AS latest
        FROM flows
        WHERE TimeReceived > now() - INTERVAL 5 MINUTE"
}

# ---------------------------------------------------------------------------
# Check 2: Which exporters are sending data?
# ---------------------------------------------------------------------------
check_exporters() {
    run_query "Exporters in last 5 minutes" "
        SELECT
          IPv6NumToString(ExporterAddress) AS exporter,
          ExporterName,
          ExporterGroup,
          ExporterRole,
          ExporterSite,
          ExporterRegion,
          count() AS flows
        FROM flows
        WHERE TimeReceived > now() - INTERVAL 5 MINUTE
        GROUP BY exporter, ExporterName, ExporterGroup, ExporterRole, ExporterSite, ExporterRegion
        ORDER BY flows DESC"
}

# ---------------------------------------------------------------------------
# Check 3: Sampling rate distribution (sFlow vs NetFlow indicator)
# ---------------------------------------------------------------------------
check_sampling() {
    run_query "Sampling rate breakdown (last 5 min)" "
        SELECT
          SamplingRate,
          count() AS flows,
          IPv6NumToString(any(ExporterAddress)) AS sample_exporter
        FROM flows
        WHERE TimeReceived > now() - INTERVAL 5 MINUTE
        GROUP BY SamplingRate
        ORDER BY flows DESC"
}

# ---------------------------------------------------------------------------
# Check 4: Top talkers (src to dst flow pairs)
# ---------------------------------------------------------------------------
check_topflows() {
    run_query "Top 20 src/dst flow pairs (last 5 min)" "
        SELECT
          IPv6NumToString(SrcAddr) AS src,
          IPv6NumToString(DstAddr) AS dst,
          count() AS flows,
          formatReadableSize(sum(Bytes * SamplingRate)) AS estimated_volume,
          formatReadableQuantity(sum(Packets * SamplingRate)) AS estimated_packets
        FROM flows
        WHERE TimeReceived > now() - INTERVAL 5 MINUTE
        GROUP BY src, dst
        ORDER BY flows DESC
        LIMIT 20"
}

# ---------------------------------------------------------------------------
# Check 5: Per-exporter volume estimates
# ---------------------------------------------------------------------------
check_volumes() {
    run_query "Per-exporter estimated traffic volume (last 5 min)" "
        SELECT
          IPv6NumToString(ExporterAddress) AS exporter,
          ExporterName,
          count() AS sampled_flows,
          formatReadableSize(sum(Bytes * SamplingRate)) AS estimated_volume,
          uniqExact(SrcAddr) AS unique_src,
          uniqExact(DstAddr) AS unique_dst
        FROM flows
        WHERE TimeReceived > now() - INTERVAL 5 MINUTE
        GROUP BY exporter, ExporterName
        ORDER BY sum(Bytes * SamplingRate) DESC"
}

# ---------------------------------------------------------------------------
# Check 6: Protocol breakdown
# ---------------------------------------------------------------------------
check_protocols() {
    run_query "Protocol breakdown (last 5 min)" "
        SELECT
          dictGetOrDefault('protocols', 'name', Proto, toString(Proto)) AS protocol,
          count() AS flows,
          formatReadableSize(sum(Bytes * SamplingRate)) AS estimated_volume
        FROM flows
        WHERE TimeReceived > now() - INTERVAL 5 MINUTE
        GROUP BY protocol
        ORDER BY flows DESC
        LIMIT 20"
}

# ---------------------------------------------------------------------------
# Check 7: Schema inspection
# ---------------------------------------------------------------------------
check_schema() {
    run_query "Flow table schema" "DESCRIBE flows"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$CHK" in
    all)
        check_total
        check_exporters
        check_sampling
        check_volumes
        check_topflows
        check_protocols
        ;;
    total)      check_total ;;
    exporters)  check_exporters ;;
    sampling)   check_sampling ;;
    topflows)   check_topflows ;;
    volumes)    check_volumes ;;
    protocols)  check_protocols ;;
    schema)     check_schema ;;
    *)
        echo "Unknown check: $CHK"
        echo ""
        echo "Available checks:"
        echo "  all        — run everything (default)"
        echo "  total      — total flows in last 5 minutes"
        echo "  exporters  — which exporters are sending"
        echo "  sampling   — sampling rate breakdown (sFlow vs NetFlow)"
        echo "  topflows   — top src/dst flow pairs"
        echo "  volumes    — per-exporter estimated volume"
        echo "  protocols  — L4 protocol breakdown"
        echo "  schema     — flow table schema"
        exit 1
        ;;
esac

echo ""
echo "============================================================"
echo "Verification complete."
echo "============================================================"
