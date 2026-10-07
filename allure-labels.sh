#!/usr/bin/env bash

# Environment variables and their corresponding Allure label names.
# Add future runner-wide labels here so every result producer uses the same mapping.
ALLURE_LABEL_MAPPINGS=(
  "TYPE_RUN:type_run"
  "TRIGGER_PIPELINE_SOURCE:trigger_pipeline_source"
)

inject_custom_allure_labels() {
  local results_dir="${1:-${TMP_DIR:-/tmp/clone}/allure-results}"
  local mapping env_name label_name label_value
  local labels_json='[]'
  local result_file temp_file
  local updated_count=0
  local had_errors=0

  for mapping in "${ALLURE_LABEL_MAPPINGS[@]}"; do
    env_name="${mapping%%:*}"
    label_name="${mapping#*:}"
    label_value="${!env_name:-}"

    [[ -z "$label_value" ]] && continue

    labels_json="$(
      jq -c \
        --arg name "$label_name" \
        --arg value "$label_value" \
        '. + [{name: $name, value: $value}]' \
        <<<"$labels_json"
    )" || {
      echo "⚠️ Failed to prepare managed Allure label '$label_name'." >&2
      return 1
    }
  done

  if [[ "$labels_json" == "[]" ]]; then
    echo "ℹ️ No custom Allure label values configured."
    return 0
  fi

  if [[ ! -d "$results_dir" ]]; then
    echo "ℹ️ Allure results directory not found; skipping custom labels: $results_dir"
    return 0
  fi

  if ! compgen -G "$results_dir/*-result.json" > /dev/null; then
    echo "ℹ️ No Allure result files found for custom labels."
    return 0
  fi

  for result_file in "$results_dir"/*-result.json; do
    temp_file="$(mktemp "${result_file}.tmp.XXXXXX")" || {
      echo "⚠️ Failed to create temporary file for '$result_file'." >&2
      had_errors=1
      continue
    }

    if jq --argjson managed_labels "$labels_json" '
      if type != "object" then
        error("Allure result must be a JSON object")
      elif (.labels? != null and (.labels | type) != "array") then
        error("Allure result labels must be an array")
      else
        ($managed_labels | map(.name)) as $managed_names
        | .labels = (
            [
              (.labels // [])[]
              | select(
                  (.name? // "") as $existing_name
                  | ($managed_names | index($existing_name)) == null
                )
            ] + $managed_labels
          )
      end
    ' "$result_file" > "$temp_file"; then
      mv -- "$temp_file" "$result_file"
      updated_count=$((updated_count + 1))
    else
      echo "⚠️ Failed to inject custom labels into '$result_file'; leaving it unchanged." >&2
      rm -f -- "$temp_file"
      had_errors=1
    fi
  done

  echo "✅ Injected custom Allure labels into $updated_count result file(s)."
  return "$had_errors"
}
