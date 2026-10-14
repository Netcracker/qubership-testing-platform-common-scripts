#!/usr/bin/env bats
# Sources every script in a clean shell, the way the runner entrypoint does, and checks that the functions
# listed in tests/smoke/manifest.txt exist afterwards. A function lost in a merge shows up here by name.

load helpers

# Source one script in a fresh shell and print the names from $3 that are not defined afterwards.
# The runner images mount this repository at /scripts, so that prefix is rewritten to the checkout.
missing_functions() {
    local script="$1" preload="$2" functions="$3" dep
    local prelude=""
    for dep in $preload; do
        prelude+="source <(sed 's|/scripts/|$REPO_ROOT/|g' '$REPO_ROOT/$dep'); "
    done
    env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" bash -c "
        set -u
        $prelude
        source <(sed 's|/scripts/|$REPO_ROOT/|g' '$REPO_ROOT/$script') || exit 99
        for fn in $functions; do declare -F \"\$fn\" >/dev/null || echo \"\$fn\"; done
    " </dev/null
}

@test "every script can be sourced and defines the functions the manifest lists" {
    local failed=0 row script preload functions out
    while IFS= read -r row; do
        IFS='|' read -r script preload functions <<<"$row"
        [ "$functions" = "-" ] && continue
        if ! out="$(missing_functions "$script" "$preload" "$functions")"; then
            echo "$script: sourcing failed" >&2
            failed=1
        elif [ -n "$out" ]; then
            echo "$script: missing functions: $(echo "$out" | tr '\n' ' ')" >&2
            failed=1
        fi
    done < <(manifest_rows)
    [ "$failed" -eq 0 ]
}
