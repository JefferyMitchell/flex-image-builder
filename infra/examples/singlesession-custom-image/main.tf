data "citrix_quickdeploy_template_image" "this" {
  name = var.image_name
}

module "catalog" {
  source = "../../modules/catalog-singlesession"

  catalog_name                    = var.catalog_name
  persona                         = var.persona
  region                          = var.region
  template_image_id               = data.citrix_quickdeploy_template_image.this.id
  number_of_users                 = var.number_of_users
  onprem_network_connection_id    = var.onprem_network_connection_id
  domain_name                     = var.domain_name
  domain_ou                       = var.domain_ou
  domain_service_account          = var.service_account
  domain_service_account_password = var.service_account_password
}
