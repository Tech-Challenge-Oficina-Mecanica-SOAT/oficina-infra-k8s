#!/usr/bin/env bash
set -euo pipefail

ENV=${1:-homolog}

CLUSTER_NAME=$(aws ssm get-parameter --name "/oficina/$ENV/k8s/cluster-name" --query Parameter.Value --output text)

aws eks update-kubeconfig --region us-east-1 --name "$CLUSTER_NAME"

# Namespace primeiro; tudo abaixo depende dele existir.
kubectl apply -f k8s/shared/namespace.yaml

# Popula o Secret (lê Parameter Store + Secrets Manager).
./scripts/populate-secret.sh "$ENV"

kubectl apply -f k8s/shared/configmap.yaml
kubectl apply -f k8s/shared/redis/
kubectl apply -f k8s/services/api/

kubectl rollout status deployment/oficina-redis -n oficina --timeout=2m
kubectl rollout status deployment/oficina-api -n oficina --timeout=5m

# O NLB leva um tempo pra provisionar depois do Service aplicado; espera até 3 min pelo hostname.
echo "Aguardando o NLB provisionar..."
LB_HOSTNAME=""
for _ in $(seq 1 18); do
  LB_HOSTNAME=$(kubectl get svc oficina-api -n oficina -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$LB_HOSTNAME" ]; then
    break
  fi
  sleep 10
done

if [ -z "$LB_HOSTNAME" ]; then
  echo "NLB ainda sem hostname após 3 min. Rode 'kubectl get svc oficina-api -n oficina' depois e publique manualmente com 'aws ssm put-parameter'."
  exit 1
fi

aws ssm put-parameter \
  --name "/oficina/$ENV/k8s/api-endpoint" \
  --type String \
  --value "http://$LB_HOSTNAME" \
  --overwrite

echo "Deploy concluído. Endpoint: http://$LB_HOSTNAME"
