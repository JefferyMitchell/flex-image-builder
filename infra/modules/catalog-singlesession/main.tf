resource "citrix_quickdeploy_catalog" "this" {
  name              = var.catalog_name
  persona           = var.persona
  catalog_type      = "SingleSessionStatic"
  region            = var.region
  subscription_name = var.subscription_name
  template_image_id = var.template_image_id
  number_of_users   = var.number_of_users

  # Needs a citrix/citrix release with enable_accelerated_networking on citrix_quickdeploy_catalog.
  # Set only at creation: changing it replaces the catalog.
  enable_accelerated_networking = var.enable_accelerated_networking

  on_prem_connectivity = var.onprem_network_connection_id != null ? {
    onprem_network_connection_id = var.onprem_network_connection_id

    domain_identity = var.domain_name != null ? {
      domain                   = var.domain_name
      domain_ou                = var.domain_ou
      service_account          = var.domain_service_account
      service_account_password = var.domain_service_account_password
    } : null
  } : null

  power_schedule = {}
}
