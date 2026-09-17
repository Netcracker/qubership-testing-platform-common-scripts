#!/usr/bin/env bats
# Unit tests for tools/b3_trace.sh — B3 trace/span id generation

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    if [ ! -r /proc/sys/kernel/random/uuid ]; then
        skip "requires /proc/sys/kernel/random/uuid (Linux only)"
    fi
    unset PROJECT_ID RUN_ID
    # shellcheck disable=SC1091
    source "$REPO_ROOT/tools/b3_trace.sh"
}

@test "generate_b3_testcase_id returns 5 lowercase hex characters" {
    run generate_b3_testcase_id
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{5}$ ]]
}

@test "generate_b3_span_id returns 16 lowercase hex characters" {
    run generate_b3_span_id
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{16}$ ]]
}

@test "generate_b3_testcase_id/span_id are not constant across calls" {
    first="$(generate_b3_span_id)"
    second="$(generate_b3_span_id)"
    [ "$first" != "$second" ]
}

@test "compose_b3_trace_id concatenates PROJECT_ID, RUN_ID and a 5-char testcase id" {
    export PROJECT_ID="proj"
    export RUN_ID="run1"
    run compose_b3_trace_id
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^projrun1[0-9a-f]{5}$ ]]
    [ "${#output}" -eq 13 ]
}

@test "compose_b3_trace_id is empty and warns when PROJECT_ID is missing" {
    unset PROJECT_ID
    export RUN_ID="run1"
    run compose_b3_trace_id
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "compose_b3_trace_id is empty and warns when RUN_ID is missing" {
    export PROJECT_ID="proj"
    unset RUN_ID
    run compose_b3_trace_id
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
