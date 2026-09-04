#!/usr/bin/env bash
set -euo pipefail

ENV=${1:-homolog}
GHCR_USERNAME=${GHCR_USERNAME:?Defina GHCR_USERNAME (seu usuario do GitHub) antes de rodar}
GHCR_PAT=${GHCR_PAT:?Defina GHCR_PAT (Personal Access Token com permissao Packages: Read-only, escopado no repo oficina-mecanica) antes de rodar}

echo "Criando/atualizando imagePullSecret para o GHCR (env=$ENV)"

kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USERNAME" \
  --docker-password="$GHCR_PAT" \
  --namespace oficina \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret 'ghcr-pull-secret' criado/atualizado no namespace 'oficina'."
