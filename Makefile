# Sobe/derruba o ambiente homolog (ou prod) numa conta AWS Academy pessoal.
# Pensado para testes individuais e gravação de vídeo, não para uso em CI/CD
# (isso continua em .github/workflows/).
#
# Uso: make up ENV=homolog INFRA_DB_DIR=../oficina-infra-db
#
# Guia detalhado (passo a passo, o que gravar em cada bloco do vídeo):
# pos-docs/Fase 3/guia-gravacao-video-p3.md

ENV ?= homolog
INFRA_DB_DIR ?= ../oficina-infra-db
AWS_REGION ?= us-east-1
CLUSTER_NAME := oficina-eks-$(ENV)

# No Git Bash (Windows), aws/helm instalados via winget às vezes não aparecem
# no PATH herdado pelo shell que o make usa para rodar as receitas, mesmo
# funcionando normalmente no PowerShell. Isso faz o creds-check acusar
# "credenciais inválidas" quando na verdade o comando aws nem foi encontrado.
# Os caminhos abaixo são acrescentados como fallback: não têm efeito se já
# estiverem no PATH, e são ignorados silenciosamente se não existirem.
AWS_CLI_FALLBACK := /c/Program Files/Amazon/AWSCLIV2
HELM_FALLBACK := $(wildcard /c/Users/*/AppData/Local/Microsoft/WinGet/Packages/Helm.Helm_Microsoft.Winget.Source_*/windows-amd64)
export PATH := $(PATH):$(AWS_CLI_FALLBACK):$(HELM_FALLBACK)
export MSYS_NO_PATHCONV=1

.PHONY: help creds-check backend-override db-apply db-destroy k8s-apply k8s-destroy \
        kubeconfig secret deploy newrelic status sanity-check up down

help:
	@echo "Uso: make <alvo> [ENV=homolog|prod] [INFRA_DB_DIR=../oficina-infra-db]"
	@echo ""
	@echo "  make up               Sobe tudo: infra-db + infra-k8s + secret + manifestos"
	@echo "  make newrelic         Instala o New Relic (requer NEW_RELIC_LICENSE_KEY exportada)"
	@echo "  make down             Derruba tudo na ordem certa e confere custo residual"
	@echo ""
	@echo "  make creds-check      Confere se as credenciais AWS estão válidas"
	@echo "  make db-apply         Sobe só o oficina-infra-db (VPC+RDS+Secrets)"
	@echo "  make db-destroy       Destroi o oficina-infra-db"
	@echo "  make k8s-apply        Sobe só o oficina-infra-k8s (EKS+regra SG)"
	@echo "  make k8s-destroy      Apaga o Service LoadBalancer e destroi o oficina-infra-k8s"
	@echo "  make kubeconfig       Configura o kubectl para o cluster"
	@echo "  make secret           Popula o Secret K8s a partir do Secrets Manager"
	@echo "  make deploy           Aplica os manifestos (namespace, redis, api, hpa)"
	@echo "  make status           Mostra nodes, pods e services"
	@echo "  make sanity-check     Confere se sobrou recurso AWS cobrando"
	@echo ""
	@echo "INFRA_DB_DIR aponta para o clone local do oficina-infra-db."
	@echo "Ajuste o valor se o seu clone não estiver ao lado deste repositório."

creds-check:
	@if ! command -v aws >/dev/null 2>&1; then \
		echo "Comando 'aws' não encontrado no PATH deste shell. Confira se o AWS CLI está instalado e no PATH."; \
		exit 1; \
	fi
	@if ! aws sts get-caller-identity; then \
		echo ""; \
		echo "Falha acima ao chamar 'aws sts get-caller-identity'. Se for erro de credenciais expiradas," ; \
		echo "renove em AWS Academy -> AWS Details -> Show, e cole em ~/.aws/credentials."; \
		exit 1; \
	fi
	@echo "Credenciais AWS OK."

backend-override: creds-check
	@if [ ! -d "$(INFRA_DB_DIR)" ]; then \
		echo "INFRA_DB_DIR '$(INFRA_DB_DIR)' não existe. Clone o oficina-infra-db ou ajuste a variável."; exit 1; \
	fi
	@if [ ! -f "$(INFRA_DB_DIR)/envs/$(ENV)/backend_override.tf" ]; then \
		printf 'terraform {\n  backend "local" {}\n}\n' > "$(INFRA_DB_DIR)/envs/$(ENV)/backend_override.tf"; \
		echo "backend_override.tf criado em $(INFRA_DB_DIR)/envs/$(ENV)/ (nunca commitar esse arquivo)."; \
	else \
		echo "backend_override.tf já existe em $(INFRA_DB_DIR)/envs/$(ENV)/, mantendo."; \
	fi

db-apply: backend-override
	cd "$(INFRA_DB_DIR)/envs/$(ENV)" && terraform init -input=false && terraform apply -auto-approve

db-destroy: creds-check
	cd "$(INFRA_DB_DIR)/envs/$(ENV)" && terraform destroy -auto-approve

k8s-apply: creds-check
	cd terraform/envs/$(ENV) && terraform init -input=false && terraform apply -auto-approve

k8s-destroy: creds-check
	kubectl delete svc oficina-api -n oficina --ignore-not-found;
	cd terraform/envs/$(ENV) && terraform destroy -auto-approve

kubeconfig: creds-check
	aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(AWS_REGION);
	kubectl get nodes;

secret:
	bash scripts/populate-secret.sh $(ENV);

deploy:
	bash scripts/deploy-manifests.sh $(ENV);

newrelic:
	@if [ -z "$$NEW_RELIC_LICENSE_KEY" ]; then \
		echo "Defina NEW_RELIC_LICENSE_KEY antes: export NEW_RELIC_LICENSE_KEY=<sua-chave>"; exit 1; \
	fi
	bash scripts/install-newrelic.sh $(ENV);

status:
	kubectl get nodes;
	@echo ""
	kubectl get pods -n oficina;
	@echo ""
	kubectl get svc -n oficina;
	@echo ""
	-kubectl get pods -n newrelic;

sanity-check: creds-check
	@echo "VPCs não default:"
	@aws ec2 describe-vpcs --filters "Name=is-default,Values=false" --query 'Vpcs[].VpcId' --output text;
	@echo "NAT Gateways:"
	@aws ec2 describe-nat-gateways --filter "Name=state,Values=available,pending" --query 'NatGateways[].NatGatewayId' --output text;
	@echo "RDS instances:"
	@aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text;
	@echo "EKS clusters:"
	@aws eks list-clusters --query 'clusters' --output text;
	@echo "Load balancers:"
	@aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text;
	@echo ""
	@echo "Tudo acima deve vir vazio. Se algo aparecer, ainda tem recurso cobrando."

up: db-apply k8s-apply kubeconfig secret deploy
	@echo ""
	@echo "Ambiente de pé. O pod da API só fica Ready quando a imagem real substituir o placeholder <ECR_URL>."
	@echo "Rode 'make newrelic' (com NEW_RELIC_LICENSE_KEY exportada) para instalar o monitoramento."

down: k8s-destroy db-destroy
	@rm -f "$(INFRA_DB_DIR)/envs/$(ENV)/backend_override.tf"
	@echo "backend_override.tf removido."
	@$(MAKE) sanity-check
