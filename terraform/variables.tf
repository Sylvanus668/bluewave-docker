variable "product" {
  description = "The product name"
  default     = "bluewave" 
}

variable "environment" {
  description = "The environment (e.g., dev, prod)"
  default     = "dev" 
}

variable "instance_type" {
  description = "The instance type"
  default     = "r6a.large"
}

variable "region" {
  description = "The region"
  default     = "us-east-1"
}

variable "github_username" {
  description = "Your GitHub username"
  default     = "Sylvanus668"
}