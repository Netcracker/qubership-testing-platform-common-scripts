#!/usr/bin/env bats
# Unit tests for the live progress index. The watch itself needs inotifywait.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    command -v jq >/dev/null || skip "jq is not installed"
    # shellcheck source=publish-test-progress.sh
    source "$REPO_ROOT/publish-test-progress.sh"
    TMP_DIR="$(mktemp -d)"
    mkdir -p "$TMP_DIR/allure-results"
    unset ATP3_JOB_NAME
}

teardown() {
    [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

_write_result() {
    local name="$1" status="$2" history="$3" stop="$4"
    cat >"$TMP_DIR/allure-results/${name}-result.json" <<EOF
{"status":"$status","historyId":"$history","fullName":"$history","uuid":"$name","stop":$stop}
EOF
}

@test "a later retry replaces the earlier status of the same test" {
    declare -A status_by_key=()
    declare -A stop_by_key=()
    _write_result first failed "login" 100
    _write_result second passed "login" 200
    _atp3_progress_ingest "$TMP_DIR/allure-results/first-result.json" status_by_key stop_by_key
    _atp3_progress_ingest "$TMP_DIR/allure-results/second-result.json" status_by_key stop_by_key
    _atp3_progress_count status_by_key
    [ "$ATP3_EXECUTED" -eq 1 ]
    [ "$ATP3_PASSED" -eq 1 ]
    [ "$ATP3_FAILED" -eq 0 ]
}

@test "an older attempt does not overwrite a newer one" {
    declare -A status_by_key=()
    declare -A stop_by_key=()
    _write_result newer failed "login" 200
    _write_result older passed "login" 100
    _atp3_progress_ingest "$TMP_DIR/allure-results/newer-result.json" status_by_key stop_by_key
    _atp3_progress_ingest "$TMP_DIR/allure-results/older-result.json" status_by_key stop_by_key
    _atp3_progress_count status_by_key
    [ "$ATP3_FAILED" -eq 1 ]
    [ "$ATP3_PASSED" -eq 0 ]
}

@test "broken counts as failed" {
    declare -A status_by_key=()
    declare -A stop_by_key=()
    _write_result one broken "boom" 10
    _write_result two skipped "skip" 10
    _atp3_progress_ingest "$TMP_DIR/allure-results/one-result.json" status_by_key stop_by_key
    _atp3_progress_ingest "$TMP_DIR/allure-results/two-result.json" status_by_key stop_by_key
    _atp3_progress_count status_by_key
    [ "$ATP3_FAILED" -eq 1 ]
    [ "$ATP3_SKIPPED" -eq 1 ]
    [ "$ATP3_EXECUTED" -eq 2 ]
}

@test "Running N tests is read from the execution log" {
    printf '\033[2mRunning \033[0m12\033[2m tests using \033[0m2 workers\n' >"$TMP_DIR/test-execution.log"
    run _atp3_progress_detect_total
    [ "$status" -eq 0 ]
    [ "$output" = "12" ]
}

@test "final publish prints executed/total and raises a short total" {
    _write_result one passed "a" 10
    _write_result two failed "b" 10
    echo 1 >"$TMP_DIR/atp3-expected-total"
    run publish_test_progress_final
    [ "$status" -eq 0 ]
    # bats joins stdout and stderr. Without ATP3_JOB_NAME the annotation step logs a skip.
    [[ "$output" == *"📈 [ATP3_PROGRESS] 2/2 passed=1 failed=1 skipped=0"* ]]
    [[ "$output" == *"ATP3_JOB_NAME is not set"* ]]
}

@test "capture total passes lines through and keeps the latest number" {
    command -v awk >/dev/null || skip "awk is not installed"
    printf 'noise\n\033[2mRunning \033[0m9\033[2m tests using \033[0m2 workers\ncollected 4 items\n' \
        | _atp3_progress_capture_total >"$TMP_DIR/capture.out"
    grep -q 'noise' "$TMP_DIR/capture.out"
    [ "$(tr -cd '0-9' <"$TMP_DIR/atp3-expected-total")" = "4" ]
}

@test "final publish keeps readable results when one file is broken" {
    _write_result one passed "a" 10
    echo 'not-json' >"$TMP_DIR/allure-results/bad-result.json"
    echo 2 >"$TMP_DIR/atp3-expected-total"
    run publish_test_progress_final
    [ "$status" -eq 0 ]
    [[ "$output" == *"📈 [ATP3_PROGRESS] 1/2 passed=1 failed=0 skipped=0"* ]]
    [[ "$output" == *"skipped unreadable result"* ]]
}
