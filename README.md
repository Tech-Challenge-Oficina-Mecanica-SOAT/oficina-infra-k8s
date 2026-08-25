# oficina-infra-k8s

> Cluster EKS e manifestos Kubernetes da Oficina Mecânica, Tech Challenge Fase 3, SOAT/FIAP.

Este repositório provisiona o cluster EKS, a regra de rede que libera o EKS para o RDS, os manifestos Kubernetes da API e do Redis compartilhado, e os scripts de deploy e observabilidade (New Relic). Depende do `oficina-infra-db` já aplicado (publica a VPC e o RDS que este repositório consome).

## Propósito

- Cluster EKS (managed node group, 1x `t3.small`) rodando a API da oficina mecânica.
- Regra de security group que libera apenas o tráfego do EKS para o RDS na porta 5432 (substitui a liberação temporária "toda a VPC" que o `oficina-infra-db` usa por padrão).
- Manifestos Kubernetes: namespace, ConfigMap, Deployment/Service/HPA da API, Redis compartilhado (cache de Idempotency-Key).
- Scripts para popular o Secret K8s a partir do Secrets Manager, fazer o deploy completo e instalar o agente do New Relic.

**Tecnologias utilizadas:** Terraform, AWS (EKS, EC2, Systems Manager Parameter Store), Kubernetes, Helm, GitHub Actions, AWS CLI, kubectl.

## Arquitetura

Decisões de design, trade-offs e descobertas feitas durante a implementação (incompatibilidades do AWS Academy, versões desatualizadas, etc.) em [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Pré-requisitos

- **Terraform** `>= 1.9.0`.
- **AWS CLI**, configurado para a região `us-east-1`.
- **kubectl**.
- **Helm** (para o agente do New Relic).
- **eksctl** (opcional, útil para depuração do cluster).
- **Credenciais do AWS Academy Learner Lab**, exportadas como `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` (expiram a cada ~4h; renove antes de rodar `apply`, os scripts de deploy ou `destroy`).
- **`oficina-infra-db` já aplicado** no mesmo ambiente (`homolog` ou `prod`) e na mesma conta AWS Academy — este repositório lê a VPC e o RDS dele via Parameter Store.

## Dependências

Este repositório consome, via SSM Parameter Store, recursos publicados pelo repositório `oficina-infra-db`:

```
/oficina/{env}/network/vpc-id
/oficina/{env}/network/private-subnet-ids
/oficina/{env}/network/public-subnet-ids
/oficina/{env}/db/endpoint
/oficina/{env}/db/port
/oficina/{env}/db/name
/oficina/{env}/db/username
/oficina/{env}/db/security-group-id
```

E do Secrets Manager: `oficina/{env}/db-password` e `oficina/{env}/jwt-secret-key`.

## Estrutura

```
terraform/
  envs/{homolog,prod}/   # composição por ambiente (eks + rds_ingress)
  modules/eks/            # cluster EKS + node group
  modules/rds-ingress/    # regra SG-to-SG entre EKS e RDS
k8s/
  shared/                 # namespace, configmap, redis (emptyDir)
  services/api/           # deployment, service (LoadBalancer/NLB), hpa
helm/
  values-newrelic.yaml    # values do chart nri-bundle
scripts/
  populate-secret.sh      # lê Parameter Store + Secrets Manager, cria o Secret K8s
  deploy-manifests.sh     # orquestra o deploy completo
  install-newrelic.sh     # helm upgrade --install do agente
docs/
  ARCHITECTURE.md         # decisões de design
```

## Estado do state do Terraform

Diferente do `oficina-infra-db` (que usa backend remoto S3 + DynamoDB), este repositório **não tem backend remoto configurado** — o state fica local em cada máquina que roda `terraform apply`. Isso é adequado enquanto cada pessoa testa na própria conta AWS Academy (estratégia de testes combinada pelo grupo), mas significa que o state não é compartilhado entre máquinas. Antes do ensaio de integração completo (todo mundo aplicando na mesma conta final), vale considerar migrar para um backend remoto — não implementado ainda, para não duplicar o bucket/tabela do `oficina-infra-db` sem necessidade real.

## Como rodar

Ordem de deploy completa, com o `oficina-infra-db` já aplicado no mesmo ambiente:

```bash
# 1. Provisionar o cluster EKS e a regra SG-to-SG
cd terraform/envs/homolog   # ou envs/prod
terraform init
terraform validate
terraform plan
terraform apply

# 2. Deploy dos manifestos (a partir da raiz do repositório)
cd ../../..
./scripts/deploy-manifests.sh homolog   # ou prod

# 3. (Opcional) Instalar o agente do New Relic
export NEW_RELIC_LICENSE_KEY="..."
./scripts/install-newrelic.sh homolog
```

`deploy-manifests.sh` já chama `populate-secret.sh` internamente; não é preciso rodar os dois separadamente.

## CI/CD

- **Plan workflow:** [`.github/workflows/plan.yml`](.github/workflows/plan.yml) — roda `terraform fmt -check` e `terraform validate` para `homolog` e `prod` automaticamente em PRs que tocam `terraform/**`.
- **Apply workflow:** [`.github/workflows/apply.yml`](.github/workflows/apply.yml) — disparo **manual** (`workflow_dispatch`), pois depende de credenciais do AWS Academy que expiram a cada 4h. Executa `terraform apply` no ambiente escolhido (`homolog` ou `prod`).

### Configurar GitHub Secrets

- **`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`:** necessários para o workflow `apply`. Adicione em `Settings → Secrets and variables → Actions`. Atualize antes de disparar o workflow, já que expiram a cada 4h.

## Testes

Validado nesta sessão contra uma conta AWS Academy real (não a final do grupo):

- `terraform fmt -check -recursive`, `terraform init`, `terraform validate`: limpos nos dois ambientes.
- `terraform apply` de ponta a ponta (cluster + node group + regra SG-to-SG): sucesso. `kubectl get nodes` confirmou o node em `Ready`. `aws ec2 describe-security-group-rules` confirmou que a regra SG-to-SG referencia de verdade o security group do EKS.
- Manifestos Kubernetes: validados com `kubectl create --dry-run=client --validate=false -f <arquivo>` (validação estrutural; não há cluster ativo permanentemente para testar `kubectl apply` real).
- `helm template` real contra o chart `newrelic/nri-bundle` usando `values-newrelic.yaml`: renderiza sem erro.
- Scripts (`populate-secret.sh`, `deploy-manifests.sh`, `install-newrelic.sh`): checados com `bash -n` (sintaxe); execução real pendente de um cluster ativo.

Infra de teste é sempre destruída ao final de cada sessão de validação (ver seção de custos abaixo).

## Como fazer destroy (⚠️ importante para o budget)

O EKS control plane e o node group continuam sendo cobrados por hora mesmo ociosos. Sempre que não for continuar no mesmo dia:

```bash
cd terraform/envs/homolog   # ou envs/prod
terraform destroy
```

Rotina recomendada por sessão de trabalho (~4h no Academy): iniciar o Lab e renovar credenciais → `terraform apply` → trabalhar/testar → `terraform destroy` antes de encerrar, se não for continuar no mesmo dia.

## Contratos publicados

Via Parameter Store (`{env}` = `homolog` ou `prod`):

```
/oficina/{env}/k8s/cluster-name
/oficina/{env}/k8s/cluster-endpoint
/oficina/{env}/k8s/cluster-security-group-id
/oficina/{env}/k8s/api-endpoint          (publicado por deploy-manifests.sh após o deploy)
```

## Repositórios relacionados

- [`oficina-infra-db`](https://github.com/Tech-Challenge-Oficina-Mecanica-SOAT/oficina-infra-db) — VPC, RDS e Secrets Manager; precisa ser aplicado antes deste repositório.
- [`oficina-mecanica-api`](https://github.com/Tech-Challenge-Oficina-Mecanica-SOAT/oficina-mecanica-api) — API .NET; a imagem publicada no ECR dela é o que o Deployment deste repositório consome.
- [`oficina-lambda-auth`](https://github.com/Tech-Challenge-Oficina-Mecanica-SOAT/oficina-lambda-auth) — Lambda de autenticação por CPF; consome o endpoint publicado por este repositório indiretamente via API Gateway.
