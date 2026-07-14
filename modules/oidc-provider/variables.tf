variable "create" {
  description = "Create the provider. False when this account already federates GitHub (an adopter's existing provider, or another stack in the SAME account already owns it — e.g. the single-account topology, where the hub and the pipeline account are one account)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for the provider."
  type        = map(string)
  default     = {}
}
