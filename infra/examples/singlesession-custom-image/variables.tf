# ── Citrix provider ────────────────────────────────────────────────────────────
variable "citrix_customer_id" { type = string }
variable "citrix_client_id"   { type = string }
# ── Custom image ───────────────────────────────────────────────────────────────
variable "image_name" {
  type        = string
  description = "Display name for the image in the Citrix library."
}

variable "vhd_uri" {
  type        = string
  description = "Azure Blob SAS URI of the exported OS disk VHD. Output of 03-export-image.ps1."
}

variable "guest_disk_uri" {
  type        = string
  description = "Azure Blob SAS URI of the VM Guest State (VMGS) disk. Required when secure_boot_enabled = true. Output of 03-export-image.ps1 when built with security_type = TrustedLaunch."
  default     = null
}

variable "os_platform" {
  type    = string
  default = "Windows"
}

variable "machine_generation" {
  type    = string
  default = "V2"
}

variable "secure_boot_enabled" {
  type    = bool
  default = true
}

variable "vtpm_enabled" {
  type    = bool
  default = true
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
