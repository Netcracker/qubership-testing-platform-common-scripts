#!/bin/bash

# Renders EnvironmentConfiguration template using pod environment variables:
#   ${VAR_NAME} -> value of $VAR_NAME (must be set; unset vars keep placeholder, warn only).

render_environment_configuration() {
    local template_path="${TMP_DIR}/EnvironmentConfiguration/environment-configuration-template.json"
    local output_path="${TMP_DIR}/environment-configuration.json"
    local template_content rendered_content placeholders placeholder var_name var_value
    local missing_vars=()

    if [ -z "${TMP_DIR:-}" ]; then
        echo "❌ ERROR: TMP_DIR is not set; cannot render environment configuration"
        return 1
    fi

    if [ ! -f "$template_path" ]; then
        echo "ℹ️ Environment configuration template not found: $template_path"
        return 0
    fi

    echo "🔄 Environment configuration template found. Starting environment systems rendering..."

    template_content="$(cat "$template_path")"
    rendered_content="$template_content"

    placeholders="$(printf '%s' "$template_content" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | sort -u || true)"

    if [ -n "$placeholders" ]; then
        while IFS= read -r placeholder; do
            [ -z "$placeholder" ] && continue
            var_name="${placeholder:2:${#placeholder}-3}"

            if [ -n "${!var_name+x}" ]; then
                var_value="${!var_name}"
                rendered_content="${rendered_content//"$placeholder"/$var_value}"
            else
                missing_vars+=("$var_name")
                echo "⚠️ Environment variable '$var_name' is not set. Leaving placeholder $placeholder as-is."
            fi
        done <<< "$placeholders"
    fi

    printf '%s' "$rendered_content" > "$output_path"
    export ATP_ENVGENE_CONFIGURATION="$rendered_content"
    export ENV_SYSTEMS="$rendered_content"

    if [ "${#missing_vars[@]}" -gt 0 ]; then
        echo "⚠️ Rendering completed with missing variables: ${missing_vars[*]}"
    fi

    echo "✅ Environment configuration rendered and saved to: $output_path"
    echo "✅ Exported rendered configuration to ATP_ENVGENE_CONFIGURATION and ENV_SYSTEMS"
}
