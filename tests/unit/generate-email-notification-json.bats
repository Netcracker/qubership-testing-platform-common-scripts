#!/usr/bin/env bats
# Unit tests for generate-email-notification-json.sh: the test_details payload must not be passed via argv,
# so large Allure result sets (more than the 128KB MAX_ARG_STRLEN limit) must still produce valid JSON.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts/email-notification/generate-email-notification-json.sh"
    command -v jq >/dev/null || skip "jq is not installed"

    # BATS_TEST_TMPDIR is not set by every bats version, so create our own scratch directory.
    WORKDIR="$(mktemp -d)"
    ALLURE_DIR="$WORKDIR/allure-results"
    OUT_DIR="$WORKDIR/out"
    mkdir -p "$ALLURE_DIR" "$OUT_DIR"

    export ALLURE_RESULTS_DIR="$ALLURE_DIR"
    export EMAIL_NOTIFICATION_OUTPUT_DIR="$OUT_DIR"
    export ENVIRONMENT_NAME="unit-test"
    export CURRENT_DATE="2026-01-01"
    export CURRENT_TIME="12-00-00"
    export ATP_REPORT_VIEW_UI_URL="https://example.com"
    export OUTPUT_FILE="$OUT_DIR/email-notification-results-generated.json"
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}

# Write N passing Allure result files, each with a long name so the total payload exceeds 128KB.
make_results() {
    local count="$1" i pad
    pad="$(printf 'x%.0s' $(seq 1 120))"
    for ((i = 1; i <= count; i++)); do
        printf '{"uuid":"u%d","historyId":"h%d","name":"test %d %s","status":"passed","start":1,"stop":2}\n' \
            "$i" "$i" "$i" "$pad" >"$ALLURE_DIR/$i-result.json"
    done
}

# Run the generator in a fresh bash so the script's function is loaded the same way the runner does.
# Used as: run bash -c "$GENERATOR_CMD" (see generator_cmd below); avoids calling a bash function through `run`.
generator_cmd() {
    printf 'source %q; generate_email_notification_json' "$SCRIPT"
}

@test "writes valid JSON when test_details exceeds the single-argument size limit" {
    make_results 2000
    # Confirm the fixture really is larger than MAX_ARG_STRLEN (128KB), otherwise the test proves nothing.
    total=$(cat "$ALLURE_DIR"/*-result.json | wc -c)
    [ "$total" -gt 131072 ]

    run bash -c "$(generator_cmd)"
    [ "$status" -eq 0 ]
    [ -f "$OUTPUT_FILE" ]
    jq empty "$OUTPUT_FILE"
    [ "$(jq '.test_details | length' "$OUTPUT_FILE")" -eq 2000 ]
    [ "$(jq -r '.test_details[0].status' "$OUTPUT_FILE")" = "PASSED" ]
}

@test "does not reference the argument-list error in the output" {
    make_results 2000
    run bash -c "$(generator_cmd)"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Argument list too long"* ]]
}

@test "writes an empty test_details array when there are no results" {
    run bash -c "$(generator_cmd)"
    jq empty "$OUTPUT_FILE"
    [ "$(jq '.test_details | length' "$OUTPUT_FILE")" -eq 0 ]
}

@test "leaves no temporary test-details file behind" {
    make_results 10
    run bash -c "$(generator_cmd)"
    [ "$status" -eq 0 ]
    [ -z "$(find "$OUT_DIR" -name 'test-details.*' -print -quit)" ]
}

@test "reports a failed build and still writes a minimal FAILED JSON" {
    make_results 3
    # Corrupt one result file so the jq -s pipeline fails.
    printf '{not json' >"$ALLURE_DIR/bad-result.json"
    run bash -c "$(generator_cmd)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to build test_details"* ]]
    jq empty "$OUTPUT_FILE"
    [ "$(jq -r '.test_results.overall_status' "$OUTPUT_FILE")" = "FAILED" ]
}
