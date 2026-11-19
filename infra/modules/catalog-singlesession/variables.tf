variable "catalog_name" {
  type        = string
  description = "Display name for the Platform Flex catalog."
}

variable "persona" {
  type        = string
  description = "SingleSession persona. Valid values: \"Knowledge worker\", \"Power worker\"."
  default     = "Knowledge worker"
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
  description = "Number of users. Each user gets a dedicated VM for SingleSessionStatic."
  default     = 1
}

variable "onprem_network_connection_id" {
  type        = string
  description = "GUID of the VNet peering Network Connection. Required for domain join or firewall routing. Set to null to deploy without VNet peering."
  default     = null
}

variable "domain_name" {
  type        = string
  description = "AD domain FQDN (e.g. \"corp.example.com\"). Set to null to deploy without domain join."
  default     = null
}

variable "domain_ou" {
  type        = string
  description = "OU path for machine accounts (e.g. \"OU=Citrix,DC=corp,DC=example,DC=com\")."
  default     = null
}

variable "domain_service_account" {
  type        = string
  description = "Username only — no domain prefix (e.g. \"flexsp\")."
  default     = null
}

variable "domain_service_account_password" {
  type        = string
  sensitive   = true
  description = "Service account password. Pass via TF_VAR_domain_service_account_password."
  default     = null
}

variable "enable_accelerated_networking" {
  type        = bool
  description = "Turn on accelerated networking on the catalog VMs' NICs. Set at creation only: changing it replaces the catalog."
  default     = true
}
