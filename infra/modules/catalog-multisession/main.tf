resource "citrix_quickdeploy_catalog" "this" {
  name              = var.catalog_name
  persona           = var.persona
  region            = var.region
  subscription_name = var.subscription_name
  template_image_id = var.template_image_id
  number_of_users   = var.number_of_users

  dynamic "on_prem_connectivity" {
    for_each = var.onprem_network_connection_id != null ? [1] : []
    content {
      onprem_network_connection_id = var.onprem_network_connection_id

      dynamic "domain_identity" {
        for_each = var.domain_name != null ? [1] : []
        content {
          domain                   = var.domain_name
          domain_ou                = var.domain_ou
          service_account          = var.domain_service_account
          service_account_password = var.domain_service_account_password
        }
      }
    }
  }

  power_schedule = {}
}
