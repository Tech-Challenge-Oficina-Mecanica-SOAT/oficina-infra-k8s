#!/usr/bin/env bash
set -euo pipefail

ENV=${1:-homolog}
NEW_RELIC_LICENSE_KEY=${NEW_RELIC_LICENSE_KEY:?License Key não definida (exporte NEW_RELIC_LICENSE_KEY)}

helm repo add newrelic https://helm-charts.newrelic.com
helm repo update

helm upgrade --install newrelic-bundle newrelic/nri-bundle \
  --version 8.0.20 \
  --namespace newrelic \
  --create-namespace \
  --values helm/values-newrelic.yaml \
  --set global.licenseKey="$NEW_RELIC_LICENSE_KEY" \
  --set global.cluster="oficina-eks-$ENV"

echo "New Relic instalado. Aguarde 2-3 min para dados aparecerem no dashboard."
