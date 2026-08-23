terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.81, < 7.0" }
  }
}

data "aws_ssm_parameter" "rds_sg_id" {
  name = "/oficina/${var.environment}/db/security-group-id"
}

data "aws_ssm_parameter" "eks_sg_id" {
  name = "/oficina/${var.environment}/k8s/cluster-security-group-id"
}

resource "aws_security_group_rule" "rds_from_eks" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = data.aws_ssm_parameter.eks_sg_id.value
  security_group_id        = data.aws_ssm_parameter.rds_sg_id.value
  description              = "Postgres 5432 do EKS cluster"
}
