variable "citrix_customer_id" {
  type        = string
  description = "Citrix Cloud customer ID."
}

variable "citrix_client_id" {
  type        = string
  description = "Citrix Cloud API client ID."
}

variable "citrix_client_secret" {
  type        = string
  sensitive   = true
  description = "Citrix Cloud API client secret. Pass via TF_VAR_citrix_client_secret."
}

variable "catalog_name" {
  type        = string
  description = "Display name for the catalog."
}

variable "persona" {
  type        = string
  default     = "Task worker (medium)"
  description = "MultiSession persona."
}

variable "region" {
  type        = string
  default     = "eastus"
  description = "Azure region ID."
}

variable "subscription_name" {
  type        = string
  default     = "Citrix Managed"
  description = "Citrix Managed Azure subscription name."
}

variable "template_image_id" {
  type        = string
  description = "GUID of the master image. Must be a MultiSession-compatible image (Windows Server or Windows Multi-session)."
}

variable "number_of_users" {
  type        = number
  default     = 8
  description = "Total concurrent sessions to support. Divided by sessions-per-VM from the persona to determine VM count."
}

variable "onprem_network_connection_id" {
  type        = string
  description = "GUID of the VNet peering Network Connection for firewall routing."
}

variable "domain_name" {
  type        = string
  description = "AD domain FQDN."
}

variable "domain_ou" {
  type        = string
  description = "OU path for machine accounts."
}

variable "domain_service_account" {
  type        = string
  description = "Service account username only (no domain prefix)."
}

variable "domain_service_account_password" {
  type        = string
  sensitive   = true
  description = "Service account password. Pass via TF_VAR_domain_service_account_password."
}
