#!/bin/bash

# Update Jira tickets referenced by generated Allure test cases.

jira_auth_header() {
    if [[ "$JIRA_BASE_URL" == *"atlassian.net"* ]]; then
        printf 'Bearer %s' "$JIRA_PASSWORD"
    else
        printf 'Basic %s' "$(printf '%s:%s' "$JIRA_USERNAME" "$JIRA_PASSWORD" | base64 -w 0)"
    fi
}

validate_jira_configuration() {
    local missing=()
    local name
    for name in JIRA_BASE_URL JIRA_USERNAME JIRA_PASSWORD JIRA_PROJECT_KEY; do
        [[ -n "${!name:-}" ]] || missing+=("$name")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "⚠️ Jira integration skipped; missing: ${missing[*]}"
        return 1
    fi
    if [[ ! "$JIRA_BASE_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]]; then
        echo "⚠️ Jira integration skipped; JIRA_BASE_URL must be an HTTPS URL"
        return 1
    fi
    JIRA_BASE_URL="${JIRA_BASE_URL%/}"
}

jira_request() {
    local endpoint="$1"
    local method="${2:-GET}"
    local body="${3:-}"
    local response http_code response_body

    if [[ ! "$endpoint" =~ ^/rest/api/[0-9]+/ ]]; then
        echo "Invalid Jira API endpoint" >&2
        return 1
    fi

    local curl_args=(
        --silent --show-error --insecure
        --connect-timeout 30
        --header "Accept: application/json"
        --header "Content-Type: application/json"
        --header "Authorization: $(jira_auth_header)"
        --request "$method"
        --write-out $'\n%{http_code}'
    )
    if [[ -n "$body" && "$method" != "GET" ]]; then
        curl_args+=(--data-binary "$body")
    fi

    if ! response=$(curl "${curl_args[@]}" "$JIRA_BASE_URL$endpoint"); then
        echo "Jira request failed: $method $endpoint" >&2
        return 1
    fi
    http_code="${response##*$'\n'}"
    response_body="${response%$'\n'*}"
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        printf '%s' "$response_body"
        return 0
    fi

    echo "Jira request failed: $method $endpoint (HTTP $http_code)" >&2
    return 1
}

test_jira_connectivity() {
    local attempt
    for attempt in 1 2 3; do
        if jira_request "/rest/api/2/myself" > /dev/null; then
            return 0
        fi
        (( attempt == 3 )) || sleep 5
    done
    echo "⚠️ Jira integration skipped; connectivity check failed"
    return 1
}

extract_jira_ticket_id() {
    local test_case_file="$1"
    local ticket search_text

    ticket=$(jq -r '
        [.labels[]? | select(.name == "jiraTicketId") | .value]
        | map(select(type == "string" and length > 0))
        | first // empty
    ' "$test_case_file")
    if [[ -n "$ticket" ]]; then
        printf '%s' "$ticket"
        return 0
    fi

    search_text=$(jq -r '[
        .name?, .fullName?, .description?,
        (.labels[]? | select((.name // "") | test("jira"; "i")) | .value?)
    ] | map(select(type == "string")) | join(" ")' "$test_case_file")
    ticket=$(printf '%s' "$search_text" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n 1)
    [[ -n "$ticket" ]] || return 1
    printf '%s' "$ticket"
}

allure_status_to_jira() {
    case "${1,,}" in
        passed) printf 'PASSED' ;;
        failed) printf 'FAILED' ;;
        skipped) printf 'SKIPPED' ;;
        broken) printf 'BROKEN' ;;
        *) printf 'FAILED' ;;
    esac
}

jira_transition_for_status() {
    case "$1" in
        PASSED) printf 'Pass' ;;
        FAILED) printf 'Fail' ;;
        BROKEN|SKIPPED) printf 'Cannot Test' ;;
    esac
}

jira_comment_for_status() {
    local status="$1"
    local test_name="$2"
    local report_url="$3"
    case "$status" in
        PASSED) printf '[PASS] Test "%s" passed successfully\n[AT] Created by Autotest\n[REPORT] Allure Report: %s' "$test_name" "$report_url" ;;
        FAILED) printf '[FAIL] Test "%s" failed\n[AT] Created by Autotest\n[REPORT] Allure Report: %s' "$test_name" "$report_url" ;;
        BROKEN) printf '[BROKEN] Test "%s" is broken\n\n[AT] Created by Autotest\n\n[REPORT] Allure Report: %s' "$test_name" "$report_url" ;;
        SKIPPED) printf '[SKIP] Test "%s" was skipped\n\n[AT] Created by Autotest\n\n[REPORT] Allure Report: %s' "$test_name" "$report_url" ;;
    esac
}

update_jira_ticket() {
    local ticket_id="$1"
    local test_name="$2"
    local status="$3"
    local report_url="$4"
    local comment transition transitions transition_id

    [[ "$ticket_id" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]] || return 1
    comment=$(jira_comment_for_status "$status" "$test_name" "$report_url")
    jira_request "/rest/api/2/issue/$ticket_id/comment" POST \
        "$(jq -cn --arg body "$comment" '{body:$body}')" > /dev/null || return 1

    transition=$(jira_transition_for_status "$status")
    [[ -n "$transition" ]] || return 0
    transitions=$(jira_request "/rest/api/2/issue/$ticket_id/transitions") || return 0
    transition_id=$(jq -r --arg name "$transition" \
        '.transitions[]? | select(.name == $name) | .id' <<< "$transitions" | head -n 1)
    if [[ -n "$transition_id" ]]; then
        jira_request "/rest/api/2/issue/$ticket_id/transitions" POST \
            "$(jq -cn --arg id "$transition_id" '{transition:{id:$id}}')" > /dev/null || true
    fi
}

run_jira_integration() {
    local report_dir="${1:-$TMP_DIR/allure-report}"
    local test_cases_dir="$report_dir/data/test-cases"
    local behaviors_file="$report_dir/data/behaviors.json"
    local behaviors_uid=""
    local base_report_url
    local file ticket_id test_name status test_uid test_url
    local processed=0 failed=0

    [[ "${ENABLE_JIRA_INTEGRATION:-false}" == "true" ]] || return 0
    validate_jira_configuration || return 0
    [[ -d "$test_cases_dir" ]] || {
        echo "⚠️ Jira integration skipped; Allure test cases are unavailable"
        return 0
    }
    test_jira_connectivity || return 0

    if [[ -f "$behaviors_file" ]]; then
        behaviors_uid=$(jq -r '.. | objects | .uid? // empty' "$behaviors_file" | head -n 1)
    fi
    base_report_url=$(allure_report_url)

    while IFS= read -r -d '' file; do
        ticket_id=$(extract_jira_ticket_id "$file") || continue
        test_name=$(jq -r '.name // .fullName // "Unknown"' "$file")
        status=$(allure_status_to_jira "$(jq -r '.status // "unknown"' "$file")")
        test_uid="$(basename "$file" .json)"
        test_url="$base_report_url"
        if [[ -n "$behaviors_uid" ]]; then
            test_url="${base_report_url}#behaviors/${behaviors_uid}/${test_uid}/"
        fi

        processed=$((processed + 1))
        if ! update_jira_ticket "$ticket_id" "$test_name" "$status" "$test_url"; then
            failed=$((failed + 1))
            echo "⚠️ Failed to update Jira ticket $ticket_id"
        fi
        sleep 1
    done < <(find "$test_cases_dir" -type f -name '*.json' -print0)

    echo "ℹ️ Jira integration processed $processed ticket(s); failures: $failed"
    return 0
}
