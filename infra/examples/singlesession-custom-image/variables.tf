# ── Citrix provider ────────────────────────────────────────────────────────────
variable "citrix_customer_id" { type = string }
variable "citrix_client_id"   { type = string }
variable "citrix_client_secret" {
  type      = string
  sensitive = true
}

# ── Custom image ───────────────────────────────────────────────────────────────
variable "image_name" {
  type        = string
  description = "Display name for the image in the Citrix library."
}

variable "vhd_uri" {
  type        = string
  description = "Azure Blob URI of the exported VHD. Output of 03-export-image script."
}

variable "os_platform" {
  type    = string
  default = "Windows"
}

variable "machine_generation" {
  type    = string
  default = "V2"
}

variable "image_notes" {
  type    = string
  default = ""
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
