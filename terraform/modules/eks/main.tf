terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.81, < 7.0" }
  }
}

data "aws_ssm_parameter" "vpc_id" {
  name = "/oficina/${var.environment}/network/vpc-id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/oficina/${var.environment}/network/private-subnet-ids"
}

# O AWS Academy Learner Lab cria LabEksClusterRole/LabEksNodeRole via CloudFormation com um
# prefixo/sufixo aleatório por conta (ex: c221562a...-LabEksClusterRole-CJjXwY0u4maq), então o
# nome literal não existe; é preciso buscar por regex. LabEksNodeRole (trust ec2.amazonaws.com,
# policies CNI/ECR-read-only/WorkerNode) é o role certo para o node group, não o LabRole genérico.
data "aws_iam_roles" "eks_cluster" {
  name_regex = "LabEksClusterRole"
}

data "aws_iam_roles" "eks_node" {
  name_regex = "LabEksNodeRole"
}

locals {
  private_subnet_ids = split(",", data.aws_ssm_parameter.private_subnet_ids.value)
  cluster_name       = "oficina-eks-${var.environment}"
  cluster_role_arn   = tolist(data.aws_iam_roles.eks_cluster.arns)[0]
  node_role_arn      = tolist(data.aws_iam_roles.eks_node.arns)[0]
}

# Cluster e node group são recursos diretos do provider, não o módulo comunitário
# terraform-aws-modules/eks/aws: esse módulo (testado nas versões v20 e v21) sempre executa
# iam:GetRole para resolver a role por trás da sessão STS atual, incondicionalmente, mesmo com
# enable_cluster_creator_admin_permissions = false. No AWS Academy essa chamada é negada pela
# política Pvoclabs2 sobre a role "voclabs", o que quebra terraform plan/apply em qualquer
# versão recente do módulo. Ver docs/ARCHITECTURE.md para o registro completo da decisão.
resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  role_arn = local.cluster_role_arn
  version  = "1.30"

  vpc_config {
    subnet_ids             = local.private_subnet_ids
    endpoint_public_access = true
  }

  # bootstrap_cluster_creator_admin_permissions concede acesso de admin a quem criou o cluster
  # do lado do serviço EKS, na chamada CreateCluster; não depende de Terraform introspectar
  # nenhuma role, então não esbarra na mesma restrição do IAM do Academy.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = {
    Project     = "oficina-mecanica"
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "oficina-infra-k8s"
  }
}

resource "aws_eks_node_group" "oficina_workers" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "oficina-workers-${var.environment}"
  node_role_arn   = local.node_role_arn
  subnet_ids      = local.private_subnet_ids
  instance_types  = ["t3.small"]

  scaling_config {
    min_size     = 1
    max_size     = 2
    desired_size = 1
  }

  tags = {
    Project     = "oficina-mecanica"
    Environment = var.environment
  }
}

resource "aws_ssm_parameter" "cluster_name" {
  name      = "/oficina/${var.environment}/k8s/cluster-name"
  type      = "String"
  value     = aws_eks_cluster.this.name
  overwrite = true
}

resource "aws_ssm_parameter" "cluster_endpoint" {
  name      = "/oficina/${var.environment}/k8s/cluster-endpoint"
  type      = "String"
  value     = aws_eks_cluster.this.endpoint
  overwrite = true
}

# Sem launch template customizado no node group, o EKS anexa automaticamente a security group
# do próprio cluster (criada por ele) às ENIs dos nodes, junto com o control plane; não existe
# uma "node security group" separada como a que o módulo comunitário cria por conta própria. É
# essa SG que precisa ganhar ingress no SG do RDS.
resource "aws_ssm_parameter" "cluster_security_group_id" {
  name      = "/oficina/${var.environment}/k8s/cluster-security-group-id"
  type      = "String"
  value     = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  overwrite = true
}
