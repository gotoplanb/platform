variable "region" {
  description = "AWS region for the state backend (matches the deploy region)."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_prefix" {
  description = "Prefix for the state bucket; the account id is appended for global uniqueness."
  type        = string
  default     = "watch-tfstate"
}

variable "lock_table_name" {
  description = "DynamoDB table name for state locks."
  type        = string
  default     = "watch-tflocks"
}
