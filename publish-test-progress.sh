#!/bin/bash

# Live test progress from $TMP_DIR/allure-results/*-result.json.
#
# The watch reads each new result file once and keeps a small index keyed by
# historyId (then fullName, then uuid). The whole directory is read only from
# publish_test_progress_final. Counts are printed as ATP3_PROGRESS and, when
# ATP3_JOB_NAME is set, patched onto the Job annotation atp3.io/test-progress.
#
# A missing Job name, token, or API is logged and ignored. Test execution
# must not fail because progress could not be published.

ATP3_PROGRESS_WATCH_PID="${ATP3_PROGRESS_WATCH_PID:-}"

_atp3_progress_stop_file() {
    printf '%s/atp3-progress.stop' "${TMP_DIR:-/tmp}"
}

_atp3_progress_lock_file() {
    printf '%s/atp3-progress.lock' "${TMP_DIR:-/tmp}"
}

# Newest attempt wins. Retries share historyId and must not add another test.
_atp3_progress_ingest() {
    local file="$1"
    local -n _st="$2"
    local -n _sp="$3"
    local status history full uuid stop key prev

    [[ -f "$file" ]] || return 0
    if ! IFS=$'\t' read -r status history full uuid stop < <(
        jq -r '[
            (.status // "unknown"),
            (.historyId // "" | gsub("[\\t\\r\\n]"; " ")),
            (.fullName // "" | gsub("[\\t\\r\\n]"; " ")),
            (.uuid // "" | gsub("[\\t\\r\\n]"; " ")),
            ((.stop // .start // 0) | tostring)
        ] | @tsv' "$file" 2>/dev/null
    ); then
        echo "⚠️ ATP3_PROGRESS skipped unreadable result: $file" >&2
        return 0
    fi

    key="$history"
    [[ -z "$key" ]] && key="$full"
    [[ -z "$key" ]] && key="$uuid"
    [[ -z "$key" ]] && key="$file"

    prev="${_sp[$key]:-}"
    if [[ -n "$prev" ]] && awk -v prev="$prev" -v cur="$stop" 'BEGIN { exit !(prev+0 > cur+0) }'; then
        return 0
    fi
    _sp["$key"]="$stop"
    _st["$key"]="$status"
}

# Sets ATP3_PASSED, ATP3_FAILED, ATP3_SKIPPED, ATP3_EXECUTED.
# broken and any other status count as failed.
_atp3_progress_count() {
    local -n _st="$1"
    local key status

    ATP3_PASSED=0
    ATP3_FAILED=0
    ATP3_SKIPPED=0
    if ((${#_st[@]} == 0)); then
        ATP3_EXECUTED=0
        return 0
    fi
    for key in "${!_st[@]}"; do
        status="${_st[$key]}"
        case "$status" in
            passed) ATP3_PASSED=$((ATP3_PASSED + 1)) ;;
            skipped) ATP3_SKIPPED=$((ATP3_SKIPPED + 1)) ;;
            *) ATP3_FAILED=$((ATP3_FAILED + 1)) ;;
        esac
    done
    ATP3_EXECUTED=$((ATP3_PASSED + ATP3_FAILED + ATP3_SKIPPED))
}

# Prints the expected total, or nothing when it is not known yet.
_atp3_progress_detect_total() {
    local expected="${TMP_DIR:-}/atp3-expected-total"
    local log="${TMP_DIR:-}/test-execution.log"
    local n="" line clean

    if [[ -f "$expected" ]]; then
        n="$(tr -cd '0-9' <"$expected" || true)"
        if [[ -n "$n" ]]; then
            printf '%s' "$n"
            return 0
        fi
    fi
    [[ -f "$log" ]] || return 0

    shopt -s extglob
    while IFS= read -r line || [[ -n "$line" ]]; do
        clean="${line//$'\e'\[+([0-9;])m/}"
        if [[ "$clean" =~ Running[[:space:]]+([0-9]+)[[:space:]]+tests?[[:space:]]+using ]]; then
            n="${BASH_REMATCH[1]}"
        elif [[ "$clean" =~ collected[[:space:]]+([0-9]+)[[:space:]]+items? ]]; then
            n="${BASH_REMATCH[1]}"
        fi
    done <"$log"
    [[ -n "$n" ]] && printf '%s' "$n"
}

_atp3_progress_patch_annotation() {
    local executed="$1" passed="$2" failed="$3" skipped="$4" total="$5" summary="$6"
    local ns token ca body code attempt job

    job="${ATP3_JOB_NAME:-}"
    if [[ -z "$job" ]]; then
        if [[ ! -f "${TMP_DIR:-/tmp}/atp3-progress.no-job" ]]; then
            echo "ℹ️ ATP3_PROGRESS annotation skipped: ATP3_JOB_NAME is not set" >&2
            : >"${TMP_DIR:-/tmp}/atp3-progress.no-job" 2>/dev/null || true
        fi
        return 0
    fi

    ns="${ATP3_RUN_NAMESPACE:-}"
    if [[ -z "$ns" && -r /var/run/secrets/kubernetes.io/serviceaccount/namespace ]]; then
        ns="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
    fi
    token="/var/run/secrets/kubernetes.io/serviceaccount/token"
    ca="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    if [[ -z "$ns" || ! -r "$token" || ! -r "$ca" ]]; then
        echo "⚠️ ATP3_PROGRESS annotation skipped: pod service account is not available" >&2
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "⚠️ ATP3_PROGRESS annotation skipped: curl is not installed" >&2
        return 0
    fi

    if [[ -n "$total" ]]; then
        body="$(jq -n \
            --argjson executed "$executed" \
            --argjson passed "$passed" \
            --argjson failed "$failed" \
            --argjson skipped "$skipped" \
            --argjson total "$total" \
            --arg summary "$summary" \
            '{metadata:{annotations:{"atp3.io/test-progress": ({executed:$executed,total:$total,passed:$passed,failed:$failed,skipped:$skipped,summary:$summary} | tojson)}}}')" || return 0
    else
        body="$(jq -n \
            --argjson executed "$executed" \
            --argjson passed "$passed" \
            --argjson failed "$failed" \
            --argjson skipped "$skipped" \
            --arg summary "$summary" \
            '{metadata:{annotations:{"atp3.io/test-progress": ({executed:$executed,total:null,passed:$passed,failed:$failed,skipped:$skipped,summary:$summary} | tojson)}}}')" || return 0
    fi

    for attempt in 1 2 3; do
        code="$(curl -sS -o "${TMP_DIR:-/tmp}/atp3-progress-patch.out" -w '%{http_code}' \
            --cacert "$ca" \
            --connect-timeout 5 \
            --max-time 15 \
            -H "Authorization: Bearer $(cat "$token")" \
            -H "Content-Type: application/merge-patch+json" \
            -X PATCH \
            --data "$body" \
            "https://kubernetes.default.svc/apis/batch/v1/namespaces/${ns}/jobs/${job}" || echo "000")"
        if [[ "$code" == "200" || "$code" == "201" ]]; then
            return 0
        fi
        if [[ "$code" != "409" ]]; then
            break
        fi
        sleep 1
    done
    echo "⚠️ ATP3_PROGRESS annotation patch failed (HTTP ${code})" >&2
    return 0
}

# final=1 raises total up to executed when the expected count was short.
_atp3_progress_emit() {
    local final="${2:-0}"
    local total summary total_log

    _atp3_progress_count "$1"
    total="$(_atp3_progress_detect_total || true)"
    if [[ "$final" == "1" && -n "$total" && "$ATP3_EXECUTED" -gt "$total" ]]; then
        total="$ATP3_EXECUTED"
    fi
    if [[ -n "$total" ]]; then
        summary="${ATP3_EXECUTED}/${total}"
        total_log="$total"
    else
        summary="${ATP3_EXECUTED}/?"
        total_log="-"
    fi

    echo "ATP3_PROGRESS executed=${ATP3_EXECUTED} total=${total_log} passed=${ATP3_PASSED} failed=${ATP3_FAILED} skipped=${ATP3_SKIPPED}"
    _atp3_progress_patch_annotation \
        "$ATP3_EXECUTED" "$ATP3_PASSED" "$ATP3_FAILED" "$ATP3_SKIPPED" "$total" "$summary" || true
}

_atp3_progress_publish_locked() {
    local final="${1:-0}"
    local lockfd

    if [[ "$final" != "1" && -f "$(_atp3_progress_stop_file)" ]]; then
        return 0
    fi
    exec {lockfd}>"$(_atp3_progress_lock_file)" || return 0
    if ! flock "$lockfd"; then
        exec {lockfd}>&-
        return 0
    fi
    if [[ "$final" != "1" && -f "$(_atp3_progress_stop_file)" ]]; then
        flock -u "$lockfd" || true
        exec {lockfd}>&-
        return 0
    fi
    _atp3_progress_emit status_by_key "$final"
    flock -u "$lockfd" || true
    exec {lockfd}>&-
}

_atp3_progress_watch_loop() {
    local dir="${TMP_DIR}/allure-results"
    local -A status_by_key=()
    local -A stop_by_key=()
    local fname pending=0 deadline=0 now wait_s inotify_pid="" fd="" read_rc=0
    local -a inotify_cmd

    mkdir -p "$dir"
    inotify_cmd=(inotifywait -m -q -e close_write -e moved_to --format '%f' "$dir")
    if command -v stdbuf >/dev/null 2>&1; then
        inotify_cmd=(stdbuf -oL "${inotify_cmd[@]}")
    fi

    exec {fd}< <("${inotify_cmd[@]}")
    inotify_pid=$!
    trap '[[ -n "${inotify_pid:-}" ]] && kill "$inotify_pid" >/dev/null 2>&1 || true' EXIT

    while true; do
        if [[ -f "$(_atp3_progress_stop_file)" ]]; then
            return 0
        fi
        now="$(date +%s)"
        if [[ "$pending" -eq 1 && "$deadline" -gt 0 && "$now" -ge "$deadline" ]]; then
            _atp3_progress_publish_locked 0 || true
            pending=0
            deadline=0
        fi
        wait_s=2
        if [[ "$pending" -eq 1 && "$deadline" -gt "$now" ]]; then
            wait_s=$((deadline - now))
            [[ "$wait_s" -lt 1 ]] && wait_s=1
        fi
        if IFS= read -r -t "$wait_s" -u "$fd" fname; then
            [[ "$fname" == *-result.json ]] || continue
            _atp3_progress_ingest "$dir/$fname" status_by_key stop_by_key
            if [[ "$pending" -eq 0 ]]; then
                deadline="$(( $(date +%s) + 2 ))"
            fi
            pending=1
        else
            read_rc=$?
            [[ "$read_rc" -gt 128 ]] || return 0
        fi
    done
}

start_test_progress_watch() {
    local dir

    [[ -n "${TMP_DIR:-}" ]] || return 0
    if ! command -v inotifywait >/dev/null 2>&1; then
        echo "ℹ️ Test progress watch skipped: inotifywait is not installed"
        return 0
    fi
    dir="${TMP_DIR}/allure-results"
    mkdir -p "$dir"
    rm -f "$(_atp3_progress_stop_file)"
    if [[ -n "${ATP3_PROGRESS_WATCH_PID:-}" ]] && kill -0 "$ATP3_PROGRESS_WATCH_PID" >/dev/null 2>&1; then
        kill "$ATP3_PROGRESS_WATCH_PID" >/dev/null 2>&1 || true
        wait "$ATP3_PROGRESS_WATCH_PID" >/dev/null 2>&1 || true
    fi
    _atp3_progress_watch_loop &
    ATP3_PROGRESS_WATCH_PID=$!
    echo "📈 Test progress watch started"
}

# One full pass after the suite finishes. Stops the live watch first so a
# stale in-memory index cannot overwrite this snapshot.
publish_test_progress_final() {
    local dir f
    local -A status_by_key=()
    local -A stop_by_key=()

    [[ -n "${TMP_DIR:-}" ]] || return 0
    : >"$(_atp3_progress_stop_file)"
    if [[ -n "${ATP3_PROGRESS_WATCH_PID:-}" ]] && kill -0 "$ATP3_PROGRESS_WATCH_PID" >/dev/null 2>&1; then
        kill "$ATP3_PROGRESS_WATCH_PID" >/dev/null 2>&1 || true
        wait "$ATP3_PROGRESS_WATCH_PID" >/dev/null 2>&1 || true
    fi
    sleep 0.2

    dir="${TMP_DIR}/allure-results"
    [[ -d "$dir" ]] || return 0
    shopt -s nullglob
    for f in "$dir"/*-result.json; do
        _atp3_progress_ingest "$f" status_by_key stop_by_key
    done
    shopt -u nullglob

    _atp3_progress_publish_locked 1 || true
}
