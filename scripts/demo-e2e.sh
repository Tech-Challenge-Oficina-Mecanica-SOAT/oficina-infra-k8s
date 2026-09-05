#!/usr/bin/env bash
set -euo pipefail

# Demo de ponta a ponta pra apresentacao: cria cliente/veiculo/OS, anda o
# ciclo de vida completo (Recebida -> ... -> Entregue) e aprova a OS
# autenticando o cliente de verdade pela Lambda (oficina-lambda-auth),
# nao com o token do Admin - prova a integracao Lambda -> API Gateway ->
# VPC Link -> NLB -> EKS -> API .NET rodando em producao.
#
# Pre-requisito (rodar uma vez, antes, nao durante a apresentacao):
#   ./scripts/bootstrap-demo-admin.sh
#
# Uso: ENV=homolog ./scripts/demo-e2e.sh
# Acompanhe ao vivo: New Relic (APM "oficina-mecanica-api" + Kubernetes)

ENV=${ENV:-homolog}
DEMO_ADMIN_EMAIL=${DEMO_ADMIN_EMAIL:-admin.demo@oficina.com}
DEMO_ADMIN_SENHA=${DEMO_ADMIN_SENHA:-SenhaForte@123}
DEMO_CPF=${DEMO_CPF:-12345678909}

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RESET='\033[0m'

step() { echo -e "\n${BOLD}${CYAN}==> $1${RESET}"; }
ok()   { echo -e "${GREEN}    $1${RESET}"; }
warn() { echo -e "${YELLOW}    $1${RESET}"; }

require_2xx() {
  local status=$1 label=$2
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "Falhou: $label (HTTP $status)"
    exit 1
  fi
}

# POST $1 com body $2 (bearer $3); imprime o id extraido ou aborta com o
# corpo do erro, pra nunca propagar um "undefined" silencioso adiante.
post_get_id() {
  local url=$1 body=$2 token=$3 label=$4
  local response status raw_body id
  response=$(curl -s -w "\n%{http_code}" -X POST "$url" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$body")
  status=$(echo "$response" | tail -n1)
  raw_body=$(echo "$response" | sed '$d')
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "Falhou: $label (HTTP $status) -> $raw_body"
    exit 1
  fi
  id=$(echo "$raw_body" | node -e "process.stdin.on('data',d=>console.log(JSON.parse(d).id))")
  echo "$id"
}

step "Descobrindo endpoints (SSM /oficina/$ENV/...)"
API_HOST=$(kubectl get svc oficina-api -n oficina -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
LAMBDA_ENDPOINT=$(aws ssm get-parameter --name "/oficina/$ENV/api-gateway/endpoint" --query Parameter.Value --output text)
ok "API (NLB direto):    http://$API_HOST"
ok "API Gateway (Lambda): $LAMBDA_ENDPOINT"

step "Login como Admin"
ADMIN_TOKEN=$(curl -s -X POST "http://$API_HOST/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$DEMO_ADMIN_EMAIL\",\"senha\":\"$DEMO_ADMIN_SENHA\"}" \
  | node -e "process.stdin.on('data',d=>{try{console.log(JSON.parse(d).token)}catch(e){console.error(d.toString());process.exit(1)}})")
ok "Token Admin obtido."

step "Limpando cliente de demo anterior (se existir)"
EXISTENTE=$(curl -s "http://$API_HOST/api/Clientes/documento/$DEMO_CPF" -H "Authorization: Bearer $ADMIN_TOKEN")
EXISTENTE_ID=$(echo "$EXISTENTE" | node -e "process.stdin.on('data',d=>{try{const j=JSON.parse(d);console.log(j.id||'')}catch(e){console.log('')}})")
if [ -n "$EXISTENTE_ID" ]; then
  curl -s -o /dev/null -X DELETE "http://$API_HOST/api/Clientes/$EXISTENTE_ID" -H "Authorization: Bearer $ADMIN_TOKEN"
  ok "Cliente de demo anterior removido ($EXISTENTE_ID)."
else
  ok "Nenhum residuo encontrado."
fi

step "Criando cliente (CPF $DEMO_CPF)"
CLIENTE_ID=$(post_get_id "http://$API_HOST/api/Clientes" \
  "{\"nome\":\"Cliente Demo Apresentacao\",\"documento\":\"$DEMO_CPF\",\"telefone\":\"11999990000\",\"email\":\"cliente.demo@oficina.com\"}" \
  "$ADMIN_TOKEN" "criar cliente")
ok "Cliente criado: $CLIENTE_ID"

step "Criando veiculo"
VEICULO_ID=$(post_get_id "http://$API_HOST/api/Veiculos" \
  "{\"clienteId\":\"$CLIENTE_ID\",\"placa\":\"DEM2026\",\"marca\":\"Fiat\",\"modelo\":\"Uno\",\"ano\":2020}" \
  "$ADMIN_TOKEN" "criar veiculo")
ok "Veiculo criado: $VEICULO_ID"

step "Abrindo Ordem de Servico"
OS_ID=$(post_get_id "http://$API_HOST/api/ordens-servico" \
  "{\"clienteId\":\"$CLIENTE_ID\",\"veiculoId\":\"$VEICULO_ID\",\"observacoes\":\"Revisao de demonstracao\"}" \
  "$ADMIN_TOKEN" "abrir OS")
ok "OS criada: $OS_ID (status: Recebida)"

transitar() {
  local rota=$1 label=$2
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH "http://$API_HOST/api/ordens-servico/$OS_ID/$rota" -H "Authorization: Bearer $ADMIN_TOKEN")
  require_2xx "$status" "$label"
  ok "$label"
}

step "Andando o ciclo de vida (Admin/Mecanico)"
transitar "iniciar-diagnostico" "Recebida -> EmDiagnostico"
transitar "enviar-para-aprovacao" "EmDiagnostico -> AguardandoAprovacao"

step "Cliente autentica pela Lambda (CPF, nao e o token do Admin)"
CLIENT_TOKEN=$(curl -s -X POST "$LAMBDA_ENDPOINT/auth/cpf" -H "Content-Type: application/json" -d "{\"cpf\":\"$DEMO_CPF\"}" \
  | node -e "process.stdin.on('data',d=>console.log(JSON.parse(d).token))")
ok "Token do cliente obtido via Lambda -> API Gateway."

step "Cliente aprova a propria OS (Lambda -> API Gateway -> VPC Link -> NLB -> EKS)"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH "$LAMBDA_ENDPOINT/api/ordens-servico/$OS_ID/aprovar" -H "Authorization: Bearer $CLIENT_TOKEN")
require_2xx "$STATUS" "AguardandoAprovacao -> EmExecucao (via Lambda)"
ok "AguardandoAprovacao -> EmExecucao (aprovado pelo cliente de verdade)"

step "Mecanico finaliza (Admin/Mecanico)"
transitar "notificar-conclusao" "EmExecucao -> Finalizada"

step "Entrega do veiculo (Admin)"
transitar "entregar" "Finalizada -> Entregue"

step "Historico completo da OS"
curl -s "http://$API_HOST/api/ordens-servico/$OS_ID/historico" -H "Authorization: Bearer $ADMIN_TOKEN" \
  | node -e "process.stdin.on('data',d=>{JSON.parse(d).forEach(h=>console.log('   '+(h.statusAnterior??'(criacao)')+' -> '+h.statusNovo+'  ['+h.alteradoPor+']'))})"

echo -e "\n${BOLD}${GREEN}Ciclo completo. OS $OS_ID: Recebida -> ... -> Entregue.${RESET}"
warn "Acompanhe em tempo real: New Relic > APM & Services > oficina-mecanica-api"
warn "                         New Relic > Kubernetes (metricas de infra)"
