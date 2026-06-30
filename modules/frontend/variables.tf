variable "name" {
  description = "Name prefix, e.g. watch-prod."
  type        = string
}

variable "env" {
  type = string
}

variable "price_class" {
  description = "CloudFront price class."
  type        = string
  default     = "PriceClass_100"
}

variable "api_origin_domain" {
  description = <<-EOT
    ALB DNS for a /api/* proxy origin so the HTTPS status page reaches the (HTTP) API
    same-origin — no mixed-content, no CORS. Empty = static-only (no API behavior).
    Becomes redundant once #13 puts HTTPS on the API domain, but harmless.
  EOT
  type        = string
  default     = ""
}

# Custom domain + ACM cert are added in #13; until then CloudFront serves on its default
# *.cloudfront.net cert.
variable "aliases" {
  type    = list(string)
  default = []
}

variable "acm_certificate_arn" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
