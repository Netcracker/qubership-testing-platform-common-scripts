#!/bin/bash

# Push atp_test_suite_start_timestamp metric BEFORE tests run.
# Called from entrypoint.sh immediately before run_tests so the timestamp
# reflects the actual suite start time, not the post-run push time.
#
# Reuses the shared helper functions from push-metrics.sh
# (_metrics_base_trim, _metrics_build_url, _metrics_auth_header, _push_to_endpoint).
# push-metrics.sh must be sourced before this file.
#
# Env vars consumed:
#   ATP_METRICS_ENABLED        - must be "true" to activate (default: false)
#   ATP_METRICS_URL - at least required
#   ENVIRONMENT_NAME       - label value for `environment`
#   CURRENT_DATE, CURRENT_TIME - used to build the push URL (set by init_environment)
#   TEST_PARAMS            - JSON string from pipeline; execution_list[0].name is used as the `name` label.

if ! declare -f _metrics_build_url > /dev/null 2>&1; then
    echo "❌ push-metrics-start.sh: push-metrics.sh must be sourced before this file." >&2
    return 1 2>/dev/null || exit 1
fi

push_metrics_start() {
    if [[ "${ATP_METRICS_ENABLED:-false}" != "true" ]]; then
        echo "ℹ️ push_metrics_start: ATP_METRICS_ENABLED is not 'true', skipping."
        return 0
    fi

    if [[ -z "${ATP_METRICS_URL:-}" ]]; then
        echo "❌ push_metrics_start: Set ATP_METRICS_URL."
        return 1
    fi

    CURRENT_DATE="${CURRENT_DATE:-$(date +%F)}"
    CURRENT_TIME="${CURRENT_TIME:-$(date +%H-%M-%S)}"
    export CURRENT_DATE CURRENT_TIME

    local start_ts
    start_ts=$(date +%s)

    local env="${ENVIRONMENT_NAME:-unknown}"
    local run_date="$CURRENT_DATE"
    local run_time="$CURRENT_TIME"

    # -------------------------------------------------------------------------
    # Resolve suite_name: TEST_PARAMS[execution_list[0].name] → EXECUTION_NAME → ""
    # (No allure-results exist yet — tests have not run.)
    # -------------------------------------------------------------------------
    local suite_name=""
    if [[ -n "${TEST_PARAMS:-}" ]]; then
        local _tp_name
        _tp_name=$(printf '%s' "$TEST_PARAMS" | jq -r '.execution_list[0].name // empty' 2>/dev/null)
        if [[ -n "$_tp_name" ]]; then
            suite_name="$_tp_name"
        fi
    fi
    local safe_suite_name="${suite_name//\"/\\\"}"
    safe_suite_name="${safe_suite_name//$'\n'/}"
    safe_suite_name="${safe_suite_name//$'\r'/}"

    local payload
    payload="# HELP atp_test_suite_start_timestamp Unix epoch seconds when the test suite started\n"
    payload+="# TYPE atp_test_suite_start_timestamp gauge\n"
    payload+="atp_test_suite_start_timestamp{environment=\"${env}\",name=\"${safe_suite_name}\"} ${start_ts}\n"

    # -------------------------------------------------------------------------
    # Push to configured endpoint(s)
    # -------------------------------------------------------------------------
    _metrics_dispatch "$FUNCNAME" "$payload" "$env" "$run_date" "$run_time"
}
