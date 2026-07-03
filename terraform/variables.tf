variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "Exactly 3 AZs, one per shard-replica placement. User MUST confirm these exist in the chosen region."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "This design assumes exactly 3 availability zones."
  }
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "clickhouse-eks"
}

variable "aws_profile" {
  description = "AWS CLI profile used for EKS token exec auth (null = default credentials)"
  type        = string
  default     = null
}
