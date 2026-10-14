#!/usr/bin/env bats
# Unit tests for the environment flags of git-clone.sh. Nothing here clones a repository.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=git-clone.sh
    source "$REPO_ROOT/git-clone.sh"
    unset ATP_TESTS_IGNORE_STRUCTURE ATP_TESTS_GIT_MODULES_IGNORE
}

@test "_is_ignore_structure is false when the flag is unset" {
    run _is_ignore_structure
    [ "$status" -eq 1 ]
}

@test "_is_ignore_structure accepts true, 1 and yes in any case, with padding" {
    local value
    for value in true TRUE 1 yes Yes "  true  "; do
        ATP_TESTS_IGNORE_STRUCTURE="$value" run _is_ignore_structure
        [ "$status" -eq 0 ]
    done
}

@test "_is_ignore_structure rejects other values" {
    local value
    for value in false 0 no maybe; do
        ATP_TESTS_IGNORE_STRUCTURE="$value" run _is_ignore_structure
        [ "$status" -eq 1 ]
    done
}

@test "_is_ignore_git_modules accepts only true" {
    ATP_TESTS_GIT_MODULES_IGNORE="TRUE" run _is_ignore_git_modules
    [ "$status" -eq 0 ]
    local value
    for value in 1 yes false ""; do
        ATP_TESTS_GIT_MODULES_IGNORE="$value" run _is_ignore_git_modules
        [ "$status" -eq 1 ]
    done
}

@test "_has_repo_markers finds a tests or app directory and rejects an empty clone" {
    local dir="$BATS_TEST_TMPDIR/clone"
    mkdir -p "$dir"
    run _has_repo_markers "$dir"
    [ "$status" -eq 1 ]
    mkdir "$dir/tests"
    run _has_repo_markers "$dir"
    [ "$status" -eq 0 ]
}
