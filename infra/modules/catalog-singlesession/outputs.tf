output "catalog_id" {
  value       = citrix_quickdeploy_catalog.this.id
  description = "GUID identifier of the deployed catalog."
}

output "catalog_name" {
  value       = citrix_quickdeploy_catalog.this.name
  description = "Name of the deployed catalog."
}
