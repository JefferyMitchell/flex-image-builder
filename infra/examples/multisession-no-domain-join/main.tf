module "catalog" {
  source = "../../modules/catalog-multisession"

  catalog_name                 = var.catalog_name
  persona                      = var.persona
  region                       = var.region
  subscription_name            = var.subscription_name
  template_image_id            = var.template_image_id
  number_of_users              = var.number_of_users
  onprem_network_connection_id = var.onprem_network_connection_id
}
