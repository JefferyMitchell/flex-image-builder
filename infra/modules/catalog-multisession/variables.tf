variable "catalog_name" {
  type        = string
  description = "Display name for the Platform Flex catalog."
}

variable "persona" {
  type        = string
  description = "MultiSession persona. Valid values: \"Task worker (medium)\", \"Task worker (heavy)\"."
  default     = "Task worker (medium)"
}

variable "region" {
  type        = string
  description = "Azure region ID (e.g. \"eastus\")."
  default     = "eastus"
}

variable "subscription_name" {
  type        = string
  description = "Citrix Managed Azure subscription name."
  default     = "Citrix Managed"
}

variable "template_image_id" {
  type        = string
  description = "GUID of the master image from Citrix Cloud Platform Flex > Images."
}

variable "number_of_users" {
  type        = number
  description = "Total number of concurrent sessions to support across the catalog."
  default     = 8
}

variable "onprem_network_connection_id" {
  type        = string
  description = "GUID of the VNet peering Network Connection. Set to null to deploy without VNet peering."
  default     = null
}

variable "domain_name" {
  type        = string
  description = "AD domain FQDN. Set to null to deploy without domain join."
  default     = null
}

variable "domain_ou" {
  type        = string
  description = "OU path for machine accounts."
  default     = null
}

variable "domain_service_account" {
  type        = string
  description = "Username only — no domain prefix."
  default     = null
}

variable "domain_service_account_password" {
  type        = string
  sensitive   = true
  description = "Service account password. Pass via TF_VAR_domain_service_account_password."
  default     = null
}
