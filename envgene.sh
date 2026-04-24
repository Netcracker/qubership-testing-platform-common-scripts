#!/usr/bin/env bash

load_envgene() {
  if [ -z "${ATP_ENVGENE_CONFIGURATION:-}" ]; then
    echo "ATP_ENVGENE_CONFIGURATION is empty, skipping EnvGene mapping"
    return 0
  fi

  echo "Loading EnvGene configuration..."

  to_env_name() {
    printf '%s\n' "$1" \
      | tr '[:lower:]' '[:upper:]' \
      | sed 's/[^A-Z0-9]/_/g'
  }

  derive_namespace_and_hostname() {
    local url="$1"
    local host namespace_part

    if [ -z "$url" ]; then
      export NAMESPACE="unknown"
      export SERVER_HOSTNAME="unknown"
      return 0
    fi

    host=$(printf '%s\n' "$url" | sed -E 's#https?://([^/]+).*#\1#')

    if [[ "$host" == public-gateway-*.* ]]; then
      namespace_part="${host#public-gateway-}"
      export NAMESPACE="${namespace_part%%.*}"

      if [[ "$host" == public-gateway-"$NAMESPACE".* ]]; then
        export SERVER_HOSTNAME="${host#public-gateway-$NAMESPACE.}"
      else
        export SERVER_HOSTNAME="$host"
      fi
    else
      export NAMESPACE="unknown"
      export SERVER_HOSTNAME="$host"
    fi
  }

  while IFS=$'\t' read -r system_name field_name field_value; do
    [ -z "$system_name" ] && continue
    [ -z "$field_name" ] && continue
    [ -z "$field_value" ] && continue

    env_name="$(to_env_name "${system_name}_${field_name}")"
    export "${env_name}=${field_value}"

    echo "   ${env_name}=${field_value}"
  done < <(
    jq -r '
      .systems[]
      | to_entries[]
      | .key as $system_name
      | .value.connections[0].HTTP? // empty
      | to_entries[]
      | select(.key == "url" or .key == "login" or .key == "password")
      | select(.value != null and .value != "")
      | [$system_name, .key, (.value | tostring)]
      | @tsv
    ' <<< "$ATP_ENVGENE_CONFIGURATION"
  )

  derive_namespace_and_hostname "${PUBLIC_GATEWAY_URL:-}"

  echo "Derived values:"
  echo "   NAMESPACE=${NAMESPACE}"
  echo "   SERVER_HOSTNAME=${SERVER_HOSTNAME}"
}