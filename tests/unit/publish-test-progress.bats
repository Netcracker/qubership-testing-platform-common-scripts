#!/usr/bin/env bats
# Unit tests for the live progress index. The watch itself needs inotifywait.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    command -v jq >/dev/null || skip "jq is not installed"
    # shellcheck source=publish-test-progress.sh
    source "$REPO_ROOT/publish-test-progress.sh"
    TMP_DIR="$(mktemp -d)"
    mkdir -p "$TMP_DIR/allure-results"
    unset ATP3_JOB_NAME ATP3_RUN_NAMESPACE ATP3_SERVICE_ACCOUNT_DIR ATP3_COLLECTION_INDEX
}

# Fake service account and curl. The stub stores the PATCH body and answers $CURL_CODE.
_fake_k8s() {
    export ATP3_JOB_NAME="atp3-run-1"
    export ATP3_RUN_NAMESPACE="ns1"
    export ATP3_SERVICE_ACCOUNT_DIR="$TMP_DIR/sa"
    mkdir -p "$ATP3_SERVICE_ACCOUNT_DIR"
    echo token >"$ATP3_SERVICE_ACCOUNT_DIR/token"
    echo ca >"$ATP3_SERVICE_ACCOUNT_DIR/ca.crt"
    CURL_CODE="${1:-200}"
    curl() {
        local prev=""
        for arg in "$@"; do
            [[ "$prev" == "--data" ]] && printf '%s' "$arg" >"$TMP_DIR/patch-body.json"
            prev="$arg"
        done
        echo x >>"$TMP_DIR/curl-calls"
        printf '%s' "$CURL_CODE"
        [[ "$CURL_CODE" != "000" ]] || return 7
    }
}

_annotation() {
    jq -r '.metadata.annotations["atp3.io/test-progress"] | fromjson' "$TMP_DIR/patch-body.json"
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

@test "empty historyId does not shift the stop column" {
    declare -A status_by_key=()
    declare -A stop_by_key=()
    printf '{"status":"failed","historyId":"","fullName":"login","uuid":"a","stop":200}\n' \
        >"$TMP_DIR/allure-results/newer-result.json"
    printf '{"status":"passed","historyId":"","fullName":"login","uuid":"b","stop":100}\n' \
        >"$TMP_DIR/allure-results/older-result.json"
    _atp3_progress_ingest_dir "$TMP_DIR/allure-results" status_by_key stop_by_key
    [ "${stop_by_key[login]}" = "200" ]
    [ "${status_by_key[login]}" = "failed" ]
}

@test "expected total is read from the capture file" {
    printf '12\n' >"$TMP_DIR/atp3-expected-total"
    run _atp3_progress_detect_total
    [ "$status" -eq 0 ]
    [ "$output" = "12" ]
}

@test "total is known once the capture or collection file has a number" {
    run _atp3_progress_total_known
    [ "$status" -eq 1 ]
    : >"$TMP_DIR/atp3-expected-total"
    run _atp3_progress_total_known
    [ "$status" -eq 1 ]
    echo 5 >"$TMP_DIR/atp3-expected-total"
    run _atp3_progress_total_known
    [ "$status" -eq 0 ]
}

@test "publish before any result reports 0/N tests with unit tests" {
    _fake_k8s 200
    echo 12 >"$TMP_DIR/atp3-expected-total"
    declare -A status_by_key=()
    run _atp3_progress_publish_locked 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"📈 [ATP3_PROGRESS] 0/12 tests: passed=0 failed=0 skipped=0"* ]]
    [ "$(_annotation | jq -c '{executed,total,unit}')" = '{"executed":0,"total":12,"unit":"tests"}' ]
}

@test "bruno annotation has unit collections" {
    _fake_k8s 200
    echo 3 >"$TMP_DIR/atp3-collections-total"
    mkdir -p "$TMP_DIR/atp3-collections-done"
    declare -A status_by_key=()
    run _atp3_progress_publish_locked 0
    [ "$status" -eq 0 ]
    [ "$(_annotation | jq -c '{executed,total,unit}')" = '{"executed":0,"total":3,"unit":"collections"}' ]
}

@test "unknown total is sent as null" {
    _fake_k8s 200
    declare -A status_by_key=()
    run _atp3_progress_publish_locked 0
    [ "$(_annotation | jq -c '.total')" = "null" ]
}

@test "403 disables later patches and is logged once" {
    _fake_k8s 403
    declare -A status_by_key=()
    run _atp3_progress_publish_locked 0
    [[ "$output" == *"annotation disabled for this run"*"HTTP 403"* ]]
    run _atp3_progress_publish_locked 0
    [[ "$output" != *"HTTP 403"* ]]
    [ "$(wc -l <"$TMP_DIR/curl-calls")" -eq 1 ]
}

@test "failed connection reports HTTP 000" {
    _fake_k8s 000
    declare -A status_by_key=()
    run _atp3_progress_publish_locked 0
    [[ "$output" == *"annotation patch failed (HTTP 000)"* ]]
}

@test "collections with the same slug get separate done marks" {
    # shellcheck source=lib/collection-runner.sh
    source "$REPO_ROOT/lib/collection-runner.sh"
    ATP3_COLLECTION_INDEX=1 _atp3_mark_collection_done "a_b"
    ATP3_COLLECTION_INDEX=2 _atp3_mark_collection_done "a_b"
    [ "$(_atp3_progress_collection_executed)" = "2" ]
}
@test "final publish prints executed/total and raises a short total" {
    _write_result one passed "a" 10
    _write_result two failed "b" 10
    echo 1 >"$TMP_DIR/atp3-expected-total"
    run publish_test_progress_final
    [ "$status" -eq 0 ]
    # bats joins stdout and stderr. Without ATP3_JOB_NAME the annotation step logs a skip.
    [[ "$output" == *"📈 [ATP3_PROGRESS] 2/2 tests: passed=1 failed=1 skipped=0"* ]]
    [[ "$output" == *"ATP3_JOB_NAME is not set"* ]]
}

@test "capture total passes lines through and keeps the latest number" {
    command -v awk >/dev/null || skip "awk is not installed"
    printf 'noise\n\033[2mRunning \033[0m9\033[2m tests using \033[0m2 workers\ncollected 4 items\n' \
        | _atp3_progress_capture_total >"$TMP_DIR/capture.out"
    grep -q 'noise' "$TMP_DIR/capture.out"
    [ "$(tr -cd '0-9' <"$TMP_DIR/atp3-expected-total")" = "4" ]
}

@test "bruno summary counts finished collections and keeps request passed/failed" {
    _write_result one passed "a" 10
    _write_result two failed "b" 10
    echo 3 >"$TMP_DIR/atp3-collections-total"
    echo 1 >"$TMP_DIR/atp3-expected-total"
    mkdir -p "$TMP_DIR/atp3-collections-done"
    : >"$TMP_DIR/atp3-collections-done/basetest"
    : >"$TMP_DIR/atp3-collections-done/orchestrator"
    run publish_test_progress_final
    [ "$status" -eq 0 ]
    [[ "$output" == *"📈 [ATP3_PROGRESS] 2/3 collections, requests: passed=1 failed=1 skipped=0"* ]]
}

@test "final publish keeps readable results when one file is broken" {
    _write_result one passed "a" 10
    echo 'not-json' >"$TMP_DIR/allure-results/bad-result.json"
    echo 2 >"$TMP_DIR/atp3-expected-total"
    run publish_test_progress_final
    [ "$status" -eq 0 ]
    [[ "$output" == *"📈 [ATP3_PROGRESS] 1/2 tests: passed=1 failed=0 skipped=0"* ]]
    [[ "$output" == *"skipped unreadable result"* ]]
}
