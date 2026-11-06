output "catalog_id" {
  value       = module.catalog.catalog_id
  description = "GUID of the deployed catalog."
}

output "catalog_name" {
  value       = module.catalog.catalog_name
  description = "Name of the deployed catalog."
}
