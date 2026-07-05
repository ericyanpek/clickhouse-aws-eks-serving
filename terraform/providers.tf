locals {
  eks_token_args = var.aws_profile != null ? ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region, "--profile", var.aws_profile] : ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
  exec {
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    args        = local.eks_token_args
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
    exec {
      api_version = "client.authentication.k8s.io/v1"
      command     = "aws"
      args        = local.eks_token_args
    }
  }
}
