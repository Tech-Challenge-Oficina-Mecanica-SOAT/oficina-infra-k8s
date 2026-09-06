#!/usr/bin/env bash
set -euo pipefail

# Cria (se nao existir) um usuario Admin pra usar nas demos/apresentacao.
# So precisa rodar uma vez por ambiente/banco - o admin criado fica valido
# ate o banco ser recriado. Rode isso ANTES da apresentacao, nao durante:
# sobe um pod temporario (postgres:16-alpine) so pra fazer a promocao a
# Admin (a rota de registro so cria Cliente; nao existe endpoint pra
# criar Admin sem ja estar autenticado como Admin).
#
# Uso: ENV=homolog DEMO_ADMIN_EMAIL=... DEMO_ADMIN_SENHA=... ./scripts/bootstrap-demo-admin.sh

ENV=${ENV:-homolog}
DEMO_ADMIN_EMAIL=${DEMO_ADMIN_EMAIL:-admin.demo@oficina.com}
DEMO_ADMIN_SENHA=${DEMO_ADMIN_SENHA:-SenhaForte@123}

API_HOST=$(kubectl get svc oficina-api -n oficina -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
if [ -z "$API_HOST" ]; then
  echo "Service oficina-api sem LoadBalancer ainda. Rode 'make up' primeiro."
  exit 1
fi

echo "Registrando $DEMO_ADMIN_EMAIL (perfil Cliente, sera promovido a seguir)..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://$API_HOST/auth/registrar" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$DEMO_ADMIN_EMAIL\",\"senha\":\"$DEMO_ADMIN_SENHA\"}")

if [ "$HTTP_STATUS" = "201" ]; then
  echo "Usuario criado."
elif [ "$HTTP_STATUS" = "409" ]; then
  echo "Usuario ja existia (email duplicado), seguindo pra promocao."
else
  echo "Registro falhou com status $HTTP_STATUS."
  exit 1
fi

echo "Promovendo a Admin via pod temporario..."
DB_HOST=$(aws ssm get-parameter --name "/oficina/$ENV/db/endpoint" --query Parameter.Value --output text)
DB_NAME=$(aws ssm get-parameter --name "/oficina/$ENV/db/name" --query Parameter.Value --output text)
DB_USER=$(aws ssm get-parameter --name "/oficina/$ENV/db/username" --query Parameter.Value --output text)
DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "oficina/$ENV/db-password" --query SecretString --output text)

kubectl run psql-bootstrap --image=postgres:16-alpine --restart=Never -n oficina --command -- sleep 60 >/dev/null
kubectl wait --for=condition=Ready pod/psql-bootstrap -n oficina --timeout=60s >/dev/null
kubectl exec -n oficina psql-bootstrap -- env PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c \
  "UPDATE \"Usuarios\" SET \"Perfil\" = 0 WHERE \"Email\" = '$DEMO_ADMIN_EMAIL';"
kubectl delete pod psql-bootstrap -n oficina --ignore-not-found >/dev/null

echo ""
echo "Admin de demo pronto: $DEMO_ADMIN_EMAIL / $DEMO_ADMIN_SENHA"
echo "Exporte antes de rodar demo-e2e.sh:"
echo "  export DEMO_ADMIN_EMAIL=$DEMO_ADMIN_EMAIL"
echo "  export DEMO_ADMIN_SENHA=$DEMO_ADMIN_SENHA"
