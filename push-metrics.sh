#!/bin/bash

# Push test result metrics to Prometheus Pushgateway / VictoriaMetrics
#
# Reads from:
#   - $GENERATED_JSON (env var set by generate_email_notification_json)
#   - /tmp/clone/allure-results/*-result.json (individual Allure result files)
#
# Feature toggle:
#   ATP_METRICS_ENABLED - set to "true" to activate (default: false)
#
# Targets (at least one base URL required when ATP_METRICS_ENABLED=true):
#   ATP_METRICS_URL         - VictoriaMetrics (or vmagent) base URL
#
# Per-target options:
#   ATP_METRICS_TYPE              - pushgateway | vm-native (default: pushgateway)
#   ATP_METRICS_AUTH_TYPE         - none | basic | bearer (default: none)
#   ATP_METRICS_USER, ATP_METRICS_PASS, ATP_METRICS_TOKEN - auth credentials
#
# Optional env vars (already exported by init_environment):
#   ENVIRONMENT_NAME
#   TEST_PARAMS        - JSON string from pipeline; execution_list[0].name is used as the `name` label.

# Strip trailing slash from base URL
_metrics_base_trim() {
    local b="${1:-}"
    b="${b%/}"
    printf '%s' "$b"
}

# Build full push URL for Pushgateway-compatible path or VM native import API.
# Args: endpoint_type base_url env
_metrics_build_url() {
    local endpoint_type="$1"
    local base_url
    base_url="$(_metrics_base_trim "$2")"
    local env="$3"

    case "$endpoint_type" in
        pushgateway)
            printf '%s' "${base_url}/metrics/job/atp_playwright_runner/instance/${env}"
            ;;
        vm-native)
            local j i
            j=$(printf '%s' 'job=atp_playwright_runner' | jq -sRr @uri)
            i=$(printf 'instance=%s' "$env" | jq -sRr @uri)
            printf '%s' "${base_url}/api/v1/import/prometheus?extra_label=${j}&extra_label=${i}"
            ;;
        *)
            echo "❌ _metrics_build_url: unknown endpoint_type '${endpoint_type}'" >&2
            return 1
            ;;
    esac
}

# Print curl-ready Authorization header line, or empty string for none / invalid.
# Args: auth_type user pass token
_metrics_auth_header() {
    local auth_type="${1:-none}"
    local user="${2:-}" pass="${3:-}" token="${4:-}"

    case "$auth_type" in
        none|"")
            return 0
            ;;
        basic)
            if [[ -z "$user" || -z "$pass" ]]; then
                echo "⚠️ push_metrics: basic auth selected but ATP_METRICS_*_USER or ATP_METRICS_*_PASS is empty." >&2
            fi
            local enc
            enc=$(printf '%s:%s' "$user" "$pass" | base64 -w0 2>/dev/null || printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')
            printf 'Authorization: Basic %s' "$enc"
            ;;
        bearer)
            if [[ -z "$token" ]]; then
                echo "⚠️ push_metrics: bearer auth selected but ATP_METRICS_*_TOKEN is empty." >&2
            fi
            printf 'Authorization: Bearer %s' "$token"
            ;;
        *)
            echo "❌ push_metrics: unknown auth type '${auth_type}' (expected none, basic, bearer)." >&2
            return 1
            ;;
    esac
}

# POST Prometheus text exposition to a single endpoint.
# Args: label url auth_header_line payload
_push_to_endpoint() {
    local label="$1" url="$2" auth_header="$3" payload="$4"

    local curl_args=(
        --insecure
        --silent
        --show-error
        --fail
        --max-time 30
        --header "Content-Type: text/plain"
        --data-binary @-
    )
    if [[ -n "$auth_header" ]]; then
        curl_args+=(--header "$auth_header")
    fi

    echo "ℹ️ push_metrics [${label}]: Pushing metrics to ${url}"

    # Send request and capture both response body and HTTP code
    response_and_code=$(printf "%b" "$payload" | curl "${curl_args[@]}" --write-out "\n%{http_code}" "$url")
    http_code=$(echo "$response_and_code" | tail -n1)

    if [[ "$http_code" =~ ^20 ]]; then
        echo "✅ push_metrics [${label}]: Metrics pushed successfully. HTTP status code: $http_code"
        return 0
    fi
    echo "❌ push_metrics [${label}]: Failed to push metrics to ${url}"
    return 1
}

# Dispatch payload to all configured Prometheus / VM endpoints.
# Args: caller_fn_name payload env
_metrics_dispatch() {
    local caller="$1" payload="$2" env="$3"
    local any_configured=false any_succeeded=false

    if [[ -n "${ATP_METRICS_URL:-}" ]]; then
        any_configured=true
        local vm_type="${ATP_METRICS_TYPE:-pushgateway}"
        case "$vm_type" in
            pushgateway|vm-native) ;;
            *) echo "❌ ${caller}: ATP_METRICS_TYPE must be pushgateway or vm-native (got: ${vm_type})." >&2
                vm_type="" ;;
        esac
        if [[ -n "$vm_type" ]]; then
            local vm_url vm_auth
            vm_url=$(_metrics_build_url "$vm_type" "$ATP_METRICS_URL" \
                "$env") || vm_url=""
            if [[ -n "$vm_url" ]]; then
                if vm_auth=$(_metrics_auth_header \
                    "${ATP_METRICS_AUTH_TYPE:-none}" \
                    "${ATP_METRICS_USER:-}" \
                    "${ATP_METRICS_PASS:-}" \
                    "${ATP_METRICS_TOKEN:-}"); then
                    if _push_to_endpoint "victoriametrics" "$vm_url" "$vm_auth" "$payload"; then
                        any_succeeded=true
                    fi
                else
                    echo "❌ ${caller}: invalid ATP_METRICS_AUTH_TYPE or auth configuration." >&2
                fi
            fi
        fi
    fi

    [[ "$any_configured" == "true" ]] || { echo "❌ ${caller}: No metrics target configured." >&2; return 1; }
    [[ "$any_succeeded" == "true" ]] || { echo "❌ ${caller}: All push targets failed." >&2; return 1; }
}

push_metrics() {
    # Feature toggle — skip silently when not enabled
    if [[ "${ATP_METRICS_ENABLED:-false}" != "true" ]]; then
        echo "ℹ️ push_metrics: ATP_METRICS_ENABLED is not 'true', skipping."
        return 0
    fi


    if [[ -z "${ATP_METRICS_URL:-}" ]]; then
        echo "❌ push_metrics: Set ATP_METRICS_URL."
        return 1
    fi

    if [[ -z "${GENERATED_JSON:-}" ]]; then
        echo "❌ push_metrics: GENERATED_JSON is not set. Run generate_email_notification_json first."
        return 1
    fi

    local allure_results_dir="/tmp/clone/allure-results"
    local env="${ENVIRONMENT_NAME:-unknown}"

    # -------------------------------------------------------------------------
    # Parse scope-level statistics from GENERATED_JSON
    # -------------------------------------------------------------------------
    local pass_rate total passed failed skipped overall_status
    pass_rate=$(echo "$GENERATED_JSON"    | jq -r '.test_results.pass_rate        // 0')
    total=$(echo "$GENERATED_JSON"        | jq -r '.test_results.total_count      // 0')
    passed=$(echo "$GENERATED_JSON"       | jq -r '.test_results.passed_count     // 0')
    failed=$(echo "$GENERATED_JSON"       | jq -r '.test_results.failed_count     // 0')
    skipped=$(echo "$GENERATED_JSON"      | jq -r '.test_results.skipped_count    // 0')
    overall_status=$(echo "$GENERATED_JSON" | jq -r '.test_results.overall_status // "UNKNOWN"')

    echo "GENERATED_JSON content parsing results:" 
    echo "pass_rate: $pass_rate"
    echo "total: $total"
    echo "passed: $passed"
    echo "failed: $failed"
    echo "skipped: $skipped"
    echo "overall_status: $overall_status"

    # -------------------------------------------------------------------------
    # Detect allure results presence
    # -------------------------------------------------------------------------
    local allure_has_results=false
    if [[ -d "$allure_results_dir" ]] && compgen -G "$allure_results_dir/*-result.json" > /dev/null 2>&1; then
        allure_has_results=true
    fi

    # -------------------------------------------------------------------------
    # Resolve suite_name: TEST_PARAMS[execution_list[0].name] → EXECUTION_NAME → first allure suite → ""
    # -------------------------------------------------------------------------
    local suite_name=""
    if [[ -n "${TEST_PARAMS:-}" ]]; then
        local _tp_name
        _tp_name=$(printf '%s' "$TEST_PARAMS" | jq -r '.execution_list[0].name // empty' 2>/dev/null)
        if [[ -n "$_tp_name" ]]; then
            suite_name="$_tp_name"
        fi
    fi
    if [[ -z "$suite_name" ]]; then
        if [[ "$allure_has_results" == "true" ]]; then
            for result_file in "$allure_results_dir"/*-result.json; do
                [[ -f "$result_file" ]] || continue
                local _s
                _s=$(jq -r '.labels[]? | select(.name=="suite") | .value' \
                    "$result_file" 2>/dev/null | head -1)
                if [[ -n "$_s" ]]; then
                    suite_name="$_s"
                    break
                fi
            done
        fi
    fi
    local safe_suite_name="${suite_name//\"/\\\"}"
    safe_suite_name="${safe_suite_name//$'\n'/}"
    safe_suite_name="${safe_suite_name//$'\r'/}"

    # -------------------------------------------------------------------------
    # Build Prometheus text-exposition payload
    # -------------------------------------------------------------------------
    local payload

    # --- Run-level pass rate ---
    payload="# HELP atp_test_suite_pass_rate Pass rate (0-100) for the entire test run\n"
    payload+="# TYPE atp_test_suite_pass_rate gauge\n"
    payload+="atp_test_suite_pass_rate{environment=\"${env}\",name=\"${safe_suite_name}\"} ${pass_rate}\n"

    # --- Run-level counts ---
    payload+="# HELP atp_test_suite_total Total number of test cases in the run\n"
    payload+="# TYPE atp_test_suite_total gauge\n"
    payload+="atp_test_suite_total{environment=\"${env}\",name=\"${safe_suite_name}\"} ${total}\n"

    payload+="# HELP atp_test_suite_passed Number of passed test cases in the run\n"
    payload+="# TYPE atp_test_suite_passed gauge\n"
    payload+="atp_test_suite_passed{environment=\"${env}\",name=\"${safe_suite_name}\"} ${passed}\n"

    payload+="# HELP atp_test_suite_failed Number of failed test cases in the run\n"
    payload+="# TYPE atp_test_suite_failed gauge\n"
    payload+="atp_test_suite_failed{environment=\"${env}\",name=\"${safe_suite_name}\"} ${failed}\n"

    payload+="# HELP atp_test_suite_skipped Number of skipped test cases in the run\n"
    payload+="# TYPE atp_test_suite_skipped gauge\n"
    payload+="atp_test_suite_skipped{environment=\"${env}\",name=\"${safe_suite_name}\"} ${skipped}\n"

    # --- Per-test-case metrics ---
    payload+="# HELP atp_test_case_result Binary result: 1=passed, 0=failed or skipped. Use the status label to distinguish skipped from failed.\n"
    payload+="# TYPE atp_test_case_result gauge\n"
    payload+="# HELP atp_test_case_duration_seconds Execution duration of the test case in seconds\n"
    payload+="# TYPE atp_test_case_duration_seconds gauge\n"

    if [[ "$allure_has_results" == "true" ]]; then
        for result_file in "$allure_results_dir"/*-result.json; do
            [[ -f "$result_file" ]] || continue

            local test_name status start_ms stop_ms suite duration result_val

            test_name=$(jq -r '.name // "unknown"' "$result_file" 2>/dev/null) || continue
            status=$(jq -r '.status // "unknown"'   "$result_file" 2>/dev/null) || continue
            start_ms=$(jq -r '.start // 0'          "$result_file" 2>/dev/null) || continue
            stop_ms=$(jq -r '.stop  // 0'           "$result_file" 2>/dev/null) || continue

            suite="$safe_suite_name"
       
            if [[ -z "${suite:-}" ]]; then
                suite=$(jq -r '.labels[]? | select(.name=="suite") | .value' \
                "$result_file" 2>/dev/null | head -1) || continue
            fi

            # Duration in seconds (Allure stores timestamps in milliseconds)
            if [[ "$start_ms" -gt 0 && "$stop_ms" -ge "$start_ms" ]] 2>/dev/null; then
                duration=$(awk "BEGIN {printf \"%.3f\", ($stop_ms - $start_ms) / 1000}")
            else
                duration="0.000"
            fi

            result_val=0
            [[ "$status" == "passed" ]] && result_val=1

            # Sanitize test_name: escape double-quotes for the Prometheus label value
            local safe_name="${test_name//\"/\\\"}"
            safe_name="${safe_name//$'\n'/}"
            safe_name="${safe_name//$'\r'/}"
            local safe_suite="${suite//\"/\\\"}"
            safe_suite="${safe_suite//$'\n'/}"
            safe_suite="${safe_suite//$'\r'/}"

            payload+="atp_test_case_result{test_name=\"${safe_name}\",environment=\"${env}\",suite=\"${safe_suite}\"} ${result_val}\n"
            payload+="atp_test_case_duration_seconds{test_name=\"${safe_name}\",environment=\"${env}\",suite=\"${safe_suite}\"} ${duration}\n"
        done
    else
        echo "⚠️ push_metrics: allure-results not found or empty, falling back to GENERATED_JSON test_details"
        local count
        count=$(echo "$GENERATED_JSON" | jq '.test_details | length')
        for ((i=0; i<count; i++)); do
            local test_name status result_val safe_name
            test_name=$(echo "$GENERATED_JSON" | jq -r ".test_details[$i].test_name")
            status=$(echo "$GENERATED_JSON"    | jq -r ".test_details[$i].status" | tr '[:upper:]' '[:lower:]')
            result_val=0
            [[ "$status" == "passed" ]] && result_val=1
            safe_name="${test_name//\"/\\\"}"
            safe_name="${safe_name//$'\n'/}"
            safe_name="${safe_name//$'\r'/}"
            payload+="atp_test_case_result{test_name=\"${safe_name}\",environment=\"${env}\",suite=\"\"} ${result_val}\n"
        done
    fi

    # -------------------------------------------------------------------------
    # Push to configured endpoint(s)
    # -------------------------------------------------------------------------
    # shellcheck disable=SC2128
    _metrics_dispatch "$FUNCNAME" "$payload" "$env"
}