# ── Citrix provider ────────────────────────────────────────────────────────────
variable "citrix_customer_id" { type = string }
variable "citrix_client_id" { type = string }

# ── Custom image lookup ────────────────────────────────────────────────────────
variable "image_name" {
  type        = string
  description = "Display name of the image as it appears in the Citrix Cloud library. Created in the portal; Terraform looks it up via data source."
}

# ── Catalog ────────────────────────────────────────────────────────────────────
variable "catalog_name" { type = string }

variable "persona" {
  type    = string
  default = "Knowledge worker"
}

variable "region" {
  type    = string
  default = "eastus"
}

variable "number_of_users" {
  type    = number
  default = 10
}

variable "onprem_network_connection_id" {
  type    = string
  default = null
}

# ── Domain join (optional) ─────────────────────────────────────────────────────
variable "domain_name" {
  type    = string
  default = null
}

variable "domain_ou" {
  type    = string
  default = null
}

variable "service_account" {
  type    = string
  default = null
}

variable "service_account_password" {
  type      = string
  sensitive = true
  default   = ""
}
