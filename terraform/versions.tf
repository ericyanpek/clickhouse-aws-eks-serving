terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40" # blueprint constraint; AWS provider v6 not yet supported upstream
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25.2, < 3.0" # v3 not yet tested against operator/monitoring resources
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.9, < 3.0" # blueprint constraint; helm provider v3 not yet supported
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # NOTE for user: configure a remote backend before real use, e.g.:
  # backend "s3" { bucket = "..." key = "clickhouse-eks/terraform.tfstate" region = "..." dynamodb_table = "..." }
}
