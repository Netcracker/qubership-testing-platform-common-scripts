#!/usr/bin/env bats
# Unit tests for assert_collection_allowed_for_runner in test-runner.sh.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # fail() comes from error-handler.sh in the runner; the test only needs to see that it is called.
    # shellcheck disable=SC2329
    fail() {
        echo "FAIL: $1"
        return 1
    }
    # shellcheck source=test-runner.sh
    source "$REPO_ROOT/test-runner.sh"
}

@test "a Playwright runner image refuses a Bruno collection" {
    ATP_APPLICATION_VERSION="atp3-playwright-runner:1.1.11-20260101" run assert_collection_allowed_for_runner
    [ "$status" -eq 1 ]
    [[ "$output" == "FAIL: use bruno to run collection"* ]]
}

@test "a Bruno runner image accepts a collection" {
    ATP_APPLICATION_VERSION="atp3-bruno-runner:1.0.0" run assert_collection_allowed_for_runner
    [ "$status" -eq 0 ]
}

@test "an unset runner identity accepts a collection" {
    unset ATP_APPLICATION_VERSION
    run assert_collection_allowed_for_runner
    [ "$status" -eq 0 ]
}
