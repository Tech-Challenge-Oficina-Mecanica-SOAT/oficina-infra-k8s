# Visão Geral da Arquitetura

Este repositório provisiona o cluster EKS que roda a aplicação da oficina mecânica e os manifestos Kubernetes usados no deploy. Documento em construção: cobre por enquanto o módulo Terraform do cluster EKS; outras seções serão adicionadas conforme os manifestos Kubernetes, o script de deploy e o New Relic forem implementados.

> Para instruções de uso, veja o [README.md](../README.md). Este documento foca nas decisões de design.

## Componentes lógicos

- `terraform/modules/eks` — cria o cluster EKS e o managed node group, consumindo a VPC publicada pelo `oficina-infra-db` via Parameter Store, e publica o nome, endpoint e security group do cluster de volta no Parameter Store.
- `terraform/modules/rds-ingress` — (a implementar) libera a porta 5432 do RDS para a security group do EKS.

## Decisão: recursos Terraform diretos em vez do módulo comunitário `terraform-aws-modules/eks/aws`

**Contexto:** o plano de implementação original previa usar o módulo `terraform-aws-modules/eks/aws` v20+, que permite reutilizar as IAM roles pré-criadas do AWS Academy (`create_iam_role = false`) em vez de criar roles próprias, que o Academy não permite.

**Problema encontrado:** testado empiricamente com `terraform plan` real contra uma conta AWS Academy, tanto na versão v20.37.2 quanto na v21.25.0 do módulo (código-fonte conferido diretamente no repositório do módulo). O módulo cria incondicionalmente um `data "aws_iam_session_context" "current"` sempre que qualquer recurso é criado (`count = local.create ? 1 : 0`, onde `local.create` é essencialmente sempre verdadeiro) — isso não depende de `enable_cluster_creator_admin_permissions`, de `kms_key_administrators` nem de nenhuma outra variável de entrada; essas variáveis só controlam o que é feito com o *resultado* da consulta, não se ela é executada.

Esse data source resolve a IAM role por trás da sessão STS atual chamando `iam:GetRole` sobre ela. No AWS Academy Learner Lab, a sessão do aluno assume a role `voclabs`, e a política gerenciada pela própria Academy (`Pvoclabs2`) **nega explicitamente** `iam:GetRole` sobre essa role — provavelmente um guard-rail intencional da Academy para impedir alunos de inspecionar/alterar a role-base da sua sessão. Resultado: `terraform plan`/`apply` falha sempre, independente de qualquer combinação de variáveis do módulo:

```
Error: unable to get role (voclabs): operation error IAM: GetRole, ...
AccessDenied: ... is not authorized to perform: iam:GetRole on resource: role voclabs
with an explicit deny in an identity-based policy: arn:aws:iam::<account>:policy/Pvoclabs2
```

**Alternativas consideradas:**
1. Fork do módulo com a linha corrigida, vendorizado como git submodule (mesmo padrão usado para o módulo VPC no `oficina-infra-db`) — mantém a API do módulo original, mas exige criar e manter um novo repositório de terceiro na org só para uma linha de patch.
2. Cópia local completa do módulo (incluindo os submódulos aninhados de node group, KMS, user-data) dentro deste repositório, com a linha corrigida — evita um novo repositório, mas commita uma quantidade grande de código de terceiro sem tracking automático de atualizações do upstream.
3. **Recursos diretos do provider AWS** (`aws_eks_cluster` + `aws_eks_node_group`) — escolhida.

**Decisão:** usar `aws_eks_cluster` e `aws_eks_node_group` diretamente. Para o caso de uso deste projeto (cluster único, uma topologia fixa, sem Fargate, sem self-managed node groups, sem múltiplos node groups), a superfície de um módulo genérico não traz benefício real, e recursos diretos evitam por completo a dependência problemática. O acesso de administrador para quem cria o cluster é resolvido de forma nativa e mais simples do que a abordagem do módulo: o bloco `access_config { bootstrap_cluster_creator_admin_permissions = true }` do próprio recurso `aws_eks_cluster` concede esse acesso do lado do serviço EKS, na chamada `CreateCluster`, sem o Terraform precisar introspectar nenhuma IAM role — não esbarra na mesma restrição do Academy.

**Consequência a observar:** sem um launch template customizado no node group, o EKS anexa automaticamente a security group do próprio cluster às ENIs dos nodes (mesmo comportamento usado para o control plane); não existe uma "node security group" dedicada como a que o módulo comunitário cria por padrão. É essa security group do cluster (`aws_eks_cluster.this.vpc_config[0].cluster_security_group_id`) que é publicada em `/oficina/{env}/k8s/cluster-security-group-id` e que vai precisar de ingress liberado no Security Group do RDS.

## Descoberta relacionada: nomes reais das IAM roles do AWS Academy

O plano original assumia nomes literais para as roles pré-criadas do Academy (`LabEksClusterRole` para o cluster, `LabRole` para o node group). Testado empiricamente nesta conta:

- `LabEksClusterRole` e `LabEksNodeRole` existem, mas com prefixo/sufixo aleatório gerado pelo CloudFormation que os provisiona (ex.: `c221562a5587885l16318665t1w568021-LabEksClusterRole-CJjXwY0u4maq`) — o nome literal não existe em nenhuma conta, é preciso buscar por regex (`data "aws_iam_roles" { name_regex = "LabEksClusterRole" }`).
- Existe uma role dedicada `LabEksNodeRole` (trust policy `ec2.amazonaws.com`, policies `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKSWorkerNodePolicy`) especificamente para node groups — mais adequada por escopo do que a `LabRole` genérica (que também funcionaria, já que aceita `ec2.amazonaws.com` como principal, mas carrega dezenas de policies de outros serviços sem relação com o node group).

## Trade-offs e decisões arquiteturais (AWS Academy)

- **1 node t3.small (`min_size = 1, max_size = 2, desired_size = 1`):** decisão de economia; em produção seriam 2+ nodes para alta disponibilidade.
- **Sem IRSA (IAM Roles for Service Accounts):** o Academy não permite criar um provedor OIDC próprio.
- **Sem chave KMS própria para secrets do etcd:** evita administração adicional de KMS neste ambiente acadêmico de ciclo de vida curto; os dados sensíveis da aplicação (senha do RDS, JWT) já são geridos separadamente via Secrets Manager pelo `oficina-infra-db`, não pelo etcd do cluster.
- **Cluster endpoint público (`endpoint_public_access = true`):** necessário para `kubectl` funcionar a partir da máquina local, fora da VPC.
