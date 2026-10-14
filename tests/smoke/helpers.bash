# Shared helpers for the smoke tests.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
MANIFEST="$REPO_ROOT/tests/smoke/manifest.txt"

# Strip the leading and trailing whitespace of the argument.
_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Print the manifest rows as "<path>|<preload>|<functions>", with the padding removed.
manifest_rows() {
    local line path preload functions
    while IFS= read -r line; do
        [[ -z "$(_trim "$line")" || "$line" == \#* ]] && continue
        IFS='|' read -r path preload functions <<<"$line"
        printf '%s|%s|%s\n' "$(_trim "$path")" "$(_trim "$preload")" "$(_trim "$functions")"
    done <"$MANIFEST"
}

# Print every shell script of the repository, relative to the root, excluding the tests themselves.
list_shell_scripts() {
    (cd "$REPO_ROOT" && find . -name '*.sh' -not -path './tests/*' -not -path './.git/*' -not -path './node_modules/*' \
        | sed 's|^\./||' | sort)
}
