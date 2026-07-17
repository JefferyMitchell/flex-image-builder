output "template_image_id" {
  description = "ID of the registered custom image in the Citrix library."
  value       = data.citrix_quickdeploy_template_image.this.id
}

output "catalog_id" {
  description = "ID of the deployed catalog."
  value       = module.catalog.catalog_id
}

output "catalog_name" {
  value = module.catalog.catalog_name
}
