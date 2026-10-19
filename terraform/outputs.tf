output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "key_vault_name" {
  description = "Utilisé par secrets.sh."
  value       = azurerm_key_vault.kv.name
}

output "postgres_host" {
  value = azurerm_postgresql_flexible_server.db.fqdn
}

output "gateway_host" {
  description = "À mettre dans PUBLIC_HOST côté Telnyx (webhook et flux audio) une fois les applications créées."
  value       = var.deploy_apps ? local.hote_gateway : null
}

output "litellm_url" {
  description = "Adresse de LiteLLM, utile seulement avec litellm_external = true (création des clés virtuelles)."
  value       = var.deploy_apps && var.litellm_external ? local.base_litellm : null
}
