locals {
  eks_token_args  = var.aws_profile != null ? ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region, "--profile", var.aws_profile] : ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  kubernetes_host = var.kube_api_endpoint_override != "" ? var.kube_api_endpoint_override : module.eks.cluster_endpoint
  kubernetes_tls_server_name = (
    var.kube_api_endpoint_override != "" ? var.kube_api_tls_server_name : null
  )
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

provider "kubernetes" {
  host                   = local.kubernetes_host
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
  tls_server_name        = local.kubernetes_tls_server_name
  exec {
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    args        = local.eks_token_args
  }
}

provider "helm" {
  kubernetes {
    host                   = local.kubernetes_host
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
    tls_server_name        = local.kubernetes_tls_server_name
    exec {
      api_version = "client.authentication.k8s.io/v1"
      command     = "aws"
      args        = local.eks_token_args
    }
  }
}
