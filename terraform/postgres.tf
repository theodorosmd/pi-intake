# Postgres 16 géré par Azure, avec pgvector. Il remplace le pod postgres du cluster et la sauvegarde de 3 h 30 :
# les sauvegardes automatiques d'Azure (7 jours ici) font ce travail.
#
# Simplification assumée pour la démonstration : les deux bases (intake et litellm) utilisent le compte
# administrateur. Sur k3s, la base intake a son propre utilisateur, sans accès à celle de LiteLLM.
# Pour retrouver cette séparation, créer deux rôles avec psql après l'installation.

resource "random_password" "db" {
  length  = 32
  special = false # évite d'avoir à encoder le mot de passe dans l'adresse de connexion
}

resource "azurerm_postgresql_flexible_server" "db" {
  name                = "psql-${var.prefix}-${random_string.suffixe.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  version             = "16"

  administrator_login    = "intakeadmin"
  administrator_password = random_password.db.result

  sku_name              = var.postgres_sku
  storage_mb            = 32768
  backup_retention_days = 7

  public_network_access_enabled = true
  tags                          = local.etiquettes

  lifecycle {
    ignore_changes = [zone] # Azure choisit la zone à la création
  }
}

# Autorise l'extension « vector » (le nom de l'extension pgvector est « vector »).
# CREATE EXTENSION vector est ensuite lancé par schema.sql au démarrage de la passerelle.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  server_id = azurerm_postgresql_flexible_server.db.id
  name      = "azure.extensions"
  value     = "VECTOR"
}

resource "azurerm_postgresql_flexible_server_database" "intake" {
  name      = "intake"
  server_id = azurerm_postgresql_flexible_server.db.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_database" "litellm" {
  name      = "litellm"
  server_id = azurerm_postgresql_flexible_server.db.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Accès : tous les services Azure (règle 0.0.0.0), connexion TLS obligatoire, mot de passe de 32 caractères.
# C'est large : n'importe quelle ressource Azure, y compris celles d'autres clients, peut tenter de se connecter.
# La version de production passe par un réseau virtuel et un sous-réseau délégué (voir README.md).
resource "azurerm_postgresql_flexible_server_firewall_rule" "services_azure" {
  name             = "AllowAllAzureServicesAndResourcesWithinAzureIps"
  server_id        = azurerm_postgresql_flexible_server.db.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Les adresses de connexion contiennent le mot de passe : elles vont dans Key Vault, jamais dans une variable d'environnement en clair.
resource "azurerm_key_vault_secret" "url_intake" {
  name         = "gateway-database-url"
  key_vault_id = azurerm_key_vault.kv.id
  value        = "postgresql://${azurerm_postgresql_flexible_server.db.administrator_login}:${random_password.db.result}@${azurerm_postgresql_flexible_server.db.fqdn}:5432/${azurerm_postgresql_flexible_server_database.intake.name}?sslmode=require"

  depends_on = [time_sleep.droits_kv]
}

resource "azurerm_key_vault_secret" "url_litellm" {
  name         = "litellm-database-url"
  key_vault_id = azurerm_key_vault.kv.id
  value        = "postgresql://${azurerm_postgresql_flexible_server.db.administrator_login}:${random_password.db.result}@${azurerm_postgresql_flexible_server.db.fqdn}:5432/${azurerm_postgresql_flexible_server_database.litellm.name}?sslmode=require"

  depends_on = [time_sleep.droits_kv]
}
