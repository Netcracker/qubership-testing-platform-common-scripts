#!/usr/bin/env bats
# Smoke tests that need no environment: every script parses, and the manifest matches the repository.
# They catch what a hand-resolved merge conflict tends to break: an unclosed block, a function defined
# twice, or a script added or dropped without the manifest following.

load helpers

@test "every shell script passes bash -n" {
    local failed=0 script
    while IFS= read -r script; do
        if ! bash -n "$REPO_ROOT/$script" 2>"$BATS_TEST_TMPDIR/err"; then
            echo "syntax error in $script:" >&2
            cat "$BATS_TEST_TMPDIR/err" >&2
            failed=1
        fi
    done < <(list_shell_scripts)
    [ "$failed" -eq 0 ]
}

@test "every JavaScript tool passes node --check" {
    command -v node >/dev/null || skip "node is not installed"
    local failed=0 script
    for script in "$REPO_ROOT"/tools/*.js; do
        node --check "$script" || { echo "syntax error in $script" >&2; failed=1; }
    done
    [ "$failed" -eq 0 ]
}

@test "no shell script defines the same top-level function twice" {
    local failed=0 script dup
    while IFS= read -r script; do
        dup="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) *\{' "$REPO_ROOT/$script" | sed -E 's/\(\).*//' | sort | uniq -d)"
        if [ -n "$dup" ]; then
            echo "$script defines twice: $(echo "$dup" | tr '\n' ' ')" >&2
            failed=1
        fi
    done < <(list_shell_scripts)
    [ "$failed" -eq 0 ]
}

@test "the manifest lists exactly the shell scripts of the repository" {
    run diff <(manifest_rows | cut -d'|' -f1 | sort) <(list_shell_scripts)
    if [ "$status" -ne 0 ]; then
        echo "tests/smoke/manifest.txt and the repository differ (< manifest, > repository):" >&2
        echo "$output" >&2
    fi
    [ "$status" -eq 0 ]
}
