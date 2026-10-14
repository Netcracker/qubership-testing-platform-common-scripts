#!/usr/bin/env bats
# Unit tests for the pure helpers of push-metrics.sh. Nothing here sends a request.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=push-metrics.sh
    source "$REPO_ROOT/push-metrics.sh"
}

@test "_metrics_base_trim removes one trailing slash" {
    run _metrics_base_trim "http://pushgateway:9091/"
    [ "$output" = "http://pushgateway:9091" ]
}

@test "_metrics_base_trim keeps a URL without a trailing slash" {
    run _metrics_base_trim "http://pushgateway:9091"
    [ "$output" = "http://pushgateway:9091" ]
}

@test "_metrics_auth_header prints nothing for auth type none or empty" {
    run _metrics_auth_header none
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run _metrics_auth_header ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_metrics_auth_header builds a Basic header from user and password" {
    run _metrics_auth_header basic alice secret
    [ "$status" -eq 0 ]
    [ "$output" = "Authorization: Basic YWxpY2U6c2VjcmV0" ]
}

@test "_metrics_auth_header builds a Bearer header from the token" {
    run _metrics_auth_header bearer "" "" tok123
    [ "$status" -eq 0 ]
    [ "$output" = "Authorization: Bearer tok123" ]
}

@test "_metrics_auth_header rejects an unknown auth type" {
    run _metrics_auth_header digest
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown auth type 'digest'"* ]]
}

@test "_metrics_build_url builds the Pushgateway path for the environment" {
    run _metrics_build_url pushgateway "http://pushgateway:9091/" dev1
    [ "$status" -eq 0 ]
    [[ "$output" == "http://pushgateway:9091/metrics/job/"*"/instance/dev1" ]]
}

@test "_metrics_build_url rejects an unknown endpoint type" {
    run _metrics_build_url graphite "http://example" dev1
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown endpoint_type 'graphite'"* ]]
}
