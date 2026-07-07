resource "citrix_quickdeploy_template_image" "this" {
  name               = var.image_name
  os_platform        = var.os_platform
  machine_generation = var.machine_generation
  region             = var.region
  subscription_name  = "Citrix Managed"
  notes              = var.image_notes
  vhd_uri            = var.vhd_uri
}

module "catalog" {
  source = "../../modules/catalog-singlesession"

  catalog_name                 = var.catalog_name
  persona                      = var.persona
  region                       = var.region
  template_image_id            = citrix_quickdeploy_template_image.this.id
  number_of_users              = var.number_of_users
  onprem_network_connection_id = var.onprem_network_connection_id
  domain_name                  = var.domain_name
  domain_ou                    = var.domain_ou
  service_account              = var.service_account
  service_account_password     = var.service_account_password
}
