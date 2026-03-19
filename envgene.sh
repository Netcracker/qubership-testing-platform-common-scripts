#!/bin/bash

load_envgene() {

  if [ -z "${ATP_ENVGENE_CONFIGURATION:-}" ]; then
    echo "ATP_ENVGENE_CONFIGURATION is empty, skipping EnvGene mapping"
    return
  fi

  echo "Loading EnvGene configuration..."

  get_value() {
    echo "$ATP_ENVGENE_CONFIGURATION" | jq -r "$1 // empty"
  }

  export PUBLIC_GATEWAY_URL=$(get_value '.systems[] | .["public-gateway"]? | .connections[0].HTTP.url')
  export PUBLIC_GATEWAY_LOGIN=$(get_value '.systems[] | .["public-gateway"]? | .connections[0].HTTP.login')
  export PUBLIC_GATEWAY_PASSWORD=$(get_value '.systems[] | .["public-gateway"]? | .connections[0].HTTP.password')

  if [ -n "$PUBLIC_GATEWAY_URL" ]; then

    host=$(echo "$PUBLIC_GATEWAY_URL" | sed -E 's#https?://([^/]+).*#\1#')

    if [[ "$host" == public-gateway-*.* ]]; then
      namespace_part=${host#public-gateway-}
      export NAMESPACE=${namespace_part%%.*}

      if [[ "$host" == public-gateway-$NAMESPACE.* ]]; then
        export SERVER_HOSTNAME=${host#public-gateway-$NAMESPACE.}
      else
        export SERVER_HOSTNAME="$host"
      fi
    else
      export NAMESPACE="unknown"
      export SERVER_HOSTNAME="$host"
    fi
  else
    export NAMESPACE="unknown"
    export SERVER_HOSTNAME="unknown"
  fi

  export PRIVATE_GATEWAY_URL=$(get_value '.systems[] | .["private-gateway"]? | .connections[0].HTTP.url')
  export INTERNAL_GATEWAY_URL=$(get_value '.systems[] | .["internal-gateway"]? | .connections[0].HTTP.url')
  export OPENSEARCH_URL=$(get_value '.systems[] | .["opensearch"]? | .connections[0].HTTP.url')
  export HUAWEI_URL=$(get_value '.systems[] | .["huawei"]? | .connections[0].HTTP.url')
  export HUAWEI_LOGIN=$(get_value '.systems[] | .["huawei"]? | .connections[0].HTTP.login')
  export HUAWEI_PASSWORD=$(get_value '.systems[] | .["huawei"]? | .connections[0].HTTP.password')
  export MONITORING_ALARM_ENGINE_URL=$(get_value '.systems[] | .["monitoring-alarm-engine"]? | .connections[0].HTTP.url')
  export KAFKA_PLATFORM_URL=$(get_value '.systems[] | .["kafka-platform"]? | .connections[0].HTTP.url')

  echo "EnvGene mapped:"
  echo "   PUBLIC_GATEWAY_URL=$PUBLIC_GATEWAY_URL"
  echo "   PRIVATE_GATEWAY_URL=$PRIVATE_GATEWAY_URL"
  echo "   INTERNAL_GATEWAY_URL=$INTERNAL_GATEWAY_URL"
  echo "   NAMESPACE=$NAMESPACE"
  echo "   SERVER_HOSTNAME=$SERVER_HOSTNAME"
  echo "   PUBLIC_GATEWAY_LOGIN=$PUBLIC_GATEWAY_LOGIN"
  echo "   PUBLIC_GATEWAY_PASSWORD=$PUBLIC_GATEWAY_PASSWORD"
}