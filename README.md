# oficina-infra-k8s

> Cluster EKS e manifestos Kubernetes da Oficina Mecânica, Tech Challenge Fase 3, SOAT/FIAP.

Este repositório provisiona o cluster EKS e os manifestos Kubernetes usados para rodar a aplicação da oficina mecânica.

## Status

Bootstrap inicial; estrutura de pastas criada, implementação em andamento.

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

## Estrutura

```
terraform/
  envs/{homolog,prod}/   # composição por ambiente
  modules/eks/           # cluster EKS + node group
  modules/rds-ingress/   # regra SG-to-SG entre EKS e RDS
k8s/
  shared/                # namespace, configmap, secret
  services/api/          # deployment, service, hpa
helm/                    # values do New Relic agent
scripts/                 # configure-kubectl, deploy-manifests, install-newrelic
```
