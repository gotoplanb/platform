
variable "permissions_boundary" {
  description = "Permissions boundary forwarded to the roles the CHILD modules create (ADR-044). This module creates no roles itself, but it must not silently drop the fence on the way down."
  type        = string
  default     = ""
}
