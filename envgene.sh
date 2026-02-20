#!/bin/bash

load_envgene() {

  if [ -z "${ATP_ENVGENE_CONFIGURATION:-}" ]; then
    echo " ATP_ENVGENE_CONFIGURATION is empty, skipping EnvGene mapping"
    return
  fi

  echo " Loading EnvGene configuration..."

  export PUBLIC_GATEWAY_URL=$(echo "$ATP_ENVGENE_CONFIGURATION" \
    | jq -r '.systems[] | .["public-gateway"]? // empty 
      | .connections[0].HTTP.url // empty')

  export PUBLIC_GATEWAY_LOGIN=$(echo "$ATP_ENVGENE_CONFIGURATION" \
    | jq -r '.systems[] | .["public-gateway"]? // empty 
      | .connections[0].HTTP.login // empty')

  export PUBLIC_GATEWAY_PASSWORD=$(echo "$ATP_ENVGENE_CONFIGURATION" \
    | jq -r '.systems[] | .["public-gateway"]? // empty 
      | .connections[0].HTTP.password // empty')


  export PRIVATE_GATEWAY_URL=$(echo "$ATP_ENVGENE_CONFIGURATION" \
    | jq -r '.systems[] | .["private-gateway"]? // empty 
      | .connections[0].HTTP.url // empty')

  export INTERNAL_GATEWAY_URL=$(echo "$ATP_ENVGENE_CONFIGURATION" \
    | jq -r '.systems[] | .["internal-gateway"]? // empty 
      | .connections[0].HTTP.url // empty')

  export OPENSEARCH_URL=$(echo "$ATP_ENVGENE_CONFIGURATION" \
    | jq -r '.systems[] | .["opensearch"]? // empty 
      | .connections[0].HTTP.url // empty')

  export HUAWEI_URL=$(echo "$ATP_ENVGENE_CONFIGURATION" \
    | jq -r '.systems[] | .["huawei"]? // empty 
      | .connections[0].HTTP.url // empty')

  export HUAWEI_LOGIN=$(echo "$ATP_ENVGENE_CONFIGURATION" \
    | jq -r '.systems[] | .["huawei"]? // empty 
      | .connections[0].HTTP.login // empty')

  export HUAWEI_PASSWORD=$(echo "$ATP_ENVGENE_CONFIGURATION" \
    | jq -r '.systems[] | .["huawei"]? // empty 
      | .connections[0].HTTP.password // empty')
  export MONITORING_ALARM_ENGINE_URL=$(echo "$ATP_ENVGENE_CONFIGURATION" \
  | jq -r '.systems[] | .["monitoring-alarm-engine"]? // empty 
    | .connections[0].HTTP.url // empty')

  export KAFKA_PLATFORM_URL=$(echo "$ATP_ENVGENE_CONFIGURATION" \
  | jq -r '.systems[] | .["kafka-platform"]? // empty 
    | .connections[0].HTTP.url // empty')


  echo "EnvGene mapped:"
  echo "   PUBLIC_GATEWAY_URL=$PUBLIC_GATEWAY_URL"
  echo "   PRIVATE_GATEWAY_URL=$PRIVATE_GATEWAY_URL"
  echo "   INTERNAL_GATEWAY_URL=$INTERNAL_GATEWAY_URL"
  echo "   OPENSEARCH_URL=$OPENSEARCH_URL"
}
