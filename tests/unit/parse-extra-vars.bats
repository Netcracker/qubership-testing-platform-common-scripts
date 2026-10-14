#!/usr/bin/env bats
# Unit tests for parse-extra-vars.sh: EXTRA_VARS parsing and test-type extraction.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=parse-extra-vars.sh
    source "$REPO_ROOT/parse-extra-vars.sh"
    unset EXTRA_VARS
}

@test "_extra_vars_trim removes leading and trailing whitespace only" {
    run _extra_vars_trim "   a b  "
    [ "$status" -eq 0 ]
    [ "$output" = "a b" ]
}

@test "parse_extra_vars does nothing when EXTRA_VARS is unset" {
    run parse_extra_vars
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "parse_extra_vars exports variables separated by semicolons and commas" {
    EXTRA_VARS="EV_ONE=1; EV_TWO = two ,EV_THREE=a=b"
    parse_extra_vars
    [ "$EV_ONE" = "1" ]
    [ "$EV_TWO" = "two" ]
    [ "$EV_THREE" = "a=b" ]
}

@test "parse_extra_vars exports variables separated by newlines" {
    EXTRA_VARS=$'EV_NL_ONE=1\nEV_NL_TWO=2'
    parse_extra_vars
    [ "$EV_NL_ONE" = "1" ]
    [ "$EV_NL_TWO" = "2" ]
}

@test "parse_extra_vars reports an overwritten variable" {
    export EV_EXISTING=old
    EXTRA_VARS="EV_EXISTING=new"
    run parse_extra_vars
    [ "$status" -eq 0 ]
    [[ "$output" == *"overwriting existing var 'EV_EXISTING'"* ]]
}

@test "parse_extra_vars rejects an entry without '='" {
    EXTRA_VARS="NO_EQUALS_SIGN"
    run parse_extra_vars
    [ "$status" -eq 1 ]
    [[ "$output" == *"no '='"* ]]
}

@test "parse_extra_vars rejects an empty variable name" {
    EXTRA_VARS="=value"
    run parse_extra_vars
    [ "$status" -eq 1 ]
    [[ "$output" == *"empty variable name"* ]]
}

@test "parse_extra_vars rejects an invalid variable name" {
    EXTRA_VARS="1BAD=value"
    run parse_extra_vars
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid variable name"* ]]
}

@test "parse_extra_vars exports nothing when a later entry is malformed" {
    EXTRA_VARS="EV_PARTIAL=1;BROKEN"
    run parse_extra_vars
    [ "$status" -eq 1 ]
    [ -z "${EV_PARTIAL:-}" ]
}

@test "extract_test_type stores the type of the execution list in the named variable" {
    command -v jq >/dev/null || skip "jq is not installed"
    # The output variable must not be called "result": extract_test_type has a local of that name,
    # so the assignment would land in the function and leave the caller's variable empty.
    local detected_type=""
    extract_test_type '{"execution_list":[{"type":"playwright"}]}' detected_type >/dev/null
    [ "$detected_type" = "playwright" ]
}
