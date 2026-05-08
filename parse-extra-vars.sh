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
