#!/bin/bash

# Flattens ATP_ENVGENE_CONFIGURATION JSON into Bruno v3 global environment.

_yaml_quote() {
    local value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

generate_bruno_global_env() {
    local workspace_dir output_path

    if [ -z "${ATP_ENVGENE_CONFIGURATION:-}" ]; then
        echo "ℹ️ ATP_ENVGENE_CONFIGURATION is empty; skipping Bruno global environment generation"
        return 0
    fi

    if [ -z "${TMP_DIR:-}" ]; then
        echo "❌ ERROR: TMP_DIR is not set; cannot generate Bruno global environment"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "❌ ERROR: 'jq' is not available; cannot generate Bruno global environment"
        return 1
    fi

    workspace_dir="${BRUNO_WORKSPACE_PATH:-$TMP_DIR}"
    : > "$workspace_dir/workspace.yml"
    output_dir="${workspace_dir}/environments"
    mkdir -p "$output_dir"
    output_file="atp-generated"
    output_path="${output_dir}/${output_file}.yml"

    if ! printf '%s' "$ATP_ENVGENE_CONFIGURATION" | jq empty >/dev/null 2>&1; then
        echo "❌ ERROR: Invalid JSON in ATP_ENVGENE_CONFIGURATION"
        return 1
    fi

    echo "🔄 Generating Bruno global environment from ATP environment configuration..."

    {
        echo "name: ${output_file}"
        echo "variables:"

        while IFS=$'\t' read -r var_name var_value; do
            [ -z "$var_name" ] && continue
            if [ "${DEBUG_MODE:-}" = "true" ]; then
                echo "🐛 DEBUG: ${var_name}=${var_value}" >&2
            fi
            echo "  - name: ${var_name}"
            echo "    value: $(_yaml_quote "$var_value")"
            echo "    enabled: true"
            # Always false: Bruno CLI ignores plaintext values when secret=true
            echo "    secret: false"
            echo "    type: text"
        done < <(
            jq -r '
              .systems[]
              | to_entries[]
              | .key as $system
              | ($system | ascii_upcase | gsub("[^A-Z0-9]"; "_")) as $sys
              | .value.connections[]
              | to_entries[]
              | .key as $conn
              | .value
              | to_entries[]
              | select(.value != null and (.value | tostring) != "")
              | .key as $param
              | (
                  $sys
                  + "_" + ($conn | ascii_upcase | gsub("[^A-Z0-9]"; "_"))
                  + "_" + ($param | ascii_upcase | gsub("[^A-Z0-9]"; "_"))
                ) as $name
              | [
                  $name,
                  (.value | tostring)
                ]
              | @tsv
            ' <<< "$ATP_ENVGENE_CONFIGURATION"
        )
    } > "$output_path"

    export BRUNO_GLOBAL_ENV="$output_file"
    export BRUNO_WORKSPACE_PATH="$workspace_dir"
    echo "✅ Bruno global environment '$output_file' written to: $output_path"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ATP_ENVGENE_CONFIGURATION="${ATP_ENVGENE_CONFIGURATION:-$(cat)}"
    TMP_DIR="${TMP_DIR:-/tmp}"
    generate_bruno_global_env
fi
