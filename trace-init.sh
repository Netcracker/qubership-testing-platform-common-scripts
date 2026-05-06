#!/bin/bash

# Portable random hex generator -- uses only /dev/urandom + od + tr
# Available on all Linux images (BusyBox on Alpine, coreutils on Ubuntu/Debian)
rand_hex() {
    local bytes=$1
    od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

generate_trace_id() {
    local raw="${ATP_PROJECT_ID:-}"
    local hex_only
    hex_only=$(printf '%s' "$raw" | tr -dc '0-9a-fA-F')
    local project_hex
    if [ -z "$hex_only" ]; then
        project_hex=$(rand_hex 4)
    else
        project_hex=$(printf '%s' "$hex_only" | rev | cut -c1-8 | rev)
        project_hex=$(printf '%08s' "$project_hex" | tr ' ' '0')
    fi
    project_hex=$(printf '%s' "$project_hex" | tr '[:upper:]' '[:lower:]')
    local run_hex
    run_hex=$(rand_hex 4)
    local step_hex
    step_hex=$(rand_hex 4)
    local random_hex
    random_hex=$(rand_hex 4)

    export ATP_TRACE_ID="${project_hex}${run_hex}${step_hex}${random_hex}"

    # Generate root span-id (64-bit = 16 hex chars)
    export ATP_SPAN_ID
    ATP_SPAN_ID=$(rand_hex 8)

    # W3C Trace Context
    export TRACEPARENT="00-${ATP_TRACE_ID}-${ATP_SPAN_ID}-01"

    # B3 propagation headers
    export X_B3_TRACEID="$ATP_TRACE_ID"
    export X_B3_SPANID="$ATP_SPAN_ID"
    export X_B3_SAMPLED="1"
}
