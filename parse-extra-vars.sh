#!/usr/bin/env bash
# Parse EXTRA_VARS into exported shell variables. Sourced by entrypoint.sh.

_extra_vars_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

parse_extra_vars() {
    [[ -z "${EXTRA_VARS:-}" ]] && return 0

    local normalized line name value
    local -a _ev_names _ev_values

    normalized="${EXTRA_VARS//;/$'\n'}"
    normalized="${normalized//,/$'\n'}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(_extra_vars_trim "$line")"
        [[ -z "$line" ]] && continue

        if [[ "$line" != *"="* ]]; then
            echo "ERROR: malformed EXTRA_VARS entry (no '='): '$line'" >&2
            return 1
        fi

        name="${line%%=*}"
        value="${line#*=}"
        name="$(_extra_vars_trim "$name")"
        value="$(_extra_vars_trim "$value")"

        if [[ -z "$name" ]]; then
            echo "ERROR: malformed EXTRA_VARS entry (empty variable name): '$line'" >&2
            return 1
        fi

        if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "ERROR: malformed EXTRA_VARS entry (invalid variable name): '$name'" >&2
            return 1
        fi

        _ev_names+=("$name")
        _ev_values+=("$value")
    done <<<"$normalized"

    local i
    for ((i = 0; i < ${#_ev_names[@]}; i++)); do
        name="${_ev_names[i]}"
        value="${_ev_values[i]}"
        if [[ -v "$name" ]]; then
            echo "INFO: EXTRA_VARS overwriting existing var '$name'"
        fi
        export "${name}=${value}"
    done

    return 0
}

# Extract test type from JSON input and store in output variable.
# Args:
#   $1 - Input JSON string
#   $2 - Name of the output variable to store the result
# ============================================
extract_test_type() {
    local input="$1"
    local output_var_name="$2"
    local result=""

    result=$(echo "$input" | jq -r '.execution_list[]?.type')
    if [[ -n "$result" ]]; then
        eval "$output_var_name=\"$result\""
    fi

    local output_message="➡️ Extracted test type:"
    echo -e "$output_message $result"
}