#!/bin/bash

log() {
    local trace_prefix=""
    if [[ -n "$ATP_TRACE_ID" ]]; then
        trace_prefix="[traceId=${ATP_TRACE_ID}] "
    fi
    echo "${trace_prefix}$*"
}
