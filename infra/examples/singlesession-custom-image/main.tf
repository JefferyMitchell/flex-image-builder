resource "citrix_quickdeploy_template_image" "this" {
  name                = var.image_name
  os_platform         = var.os_platform
  machine_generation  = var.machine_generation
  region              = var.region
  subscription_name   = "Citrix Managed"
  notes               = var.image_notes
  vhd_uri             = var.vhd_uri
  guest_disk_uri      = var.guest_disk_uri
  secure_boot_enabled = var.secure_boot_enabled
  vtpm_enabled        = var.vtpm_enabled
}

module "catalog" {
  source = "../../modules/catalog-multisession"

  catalog_name                    = var.catalog_name
  persona                         = var.persona
  region                          = var.region
  template_image_id               = citrix_quickdeploy_template_image.this.id
  number_of_users                 = var.number_of_users
  onprem_network_connection_id    = var.onprem_network_connection_id
  domain_name                     = var.domain_name
  domain_ou                       = var.domain_ou
  domain_service_account          = var.service_account
  domain_service_account_password = var.service_account_password
}
