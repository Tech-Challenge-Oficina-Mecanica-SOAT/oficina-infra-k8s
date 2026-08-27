#!/usr/bin/env bash
set -euo pipefail

ENV=${1:-homolog}

echo "Populando Secret K8s a partir do Secrets Manager para env=$ENV"

DB_ENDPOINT=$(aws ssm get-parameter --name "/oficina/$ENV/db/endpoint" --query Parameter.Value --output text)
DB_PORT=$(aws ssm get-parameter --name "/oficina/$ENV/db/port" --query Parameter.Value --output text)
DB_NAME=$(aws ssm get-parameter --name "/oficina/$ENV/db/name" --query Parameter.Value --output text)
DB_USER=$(aws ssm get-parameter --name "/oficina/$ENV/db/username" --query Parameter.Value --output text)
DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "oficina/$ENV/db-password" --query SecretString --output text)
JWT_SECRET=$(aws secretsmanager get-secret-value --secret-id "oficina/$ENV/jwt-secret-key" --query SecretString --output text)

CONNECTION_STRING="Host=$DB_ENDPOINT;Port=$DB_PORT;Database=$DB_NAME;Username=$DB_USER;Password=$DB_PASSWORD;Trust Server Certificate=true"

kubectl create secret generic oficina-secrets \
  --namespace oficina \
  --from-literal=ConnectionStrings__DefaultConnection="$CONNECTION_STRING" \
  --from-literal=Jwt__SecretKey="$JWT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret 'oficina-secrets' criado/atualizado no namespace 'oficina'."
