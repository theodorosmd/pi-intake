# Infrastructure Azure de la passerelle d'appel : l'équivalent, sur Azure, de ce que chart/ installe sur k3s.
# Rien ici ne contient de secret : les clés d'API passent par Key Vault (secrets.sh), le mot de passe de la
# base est généré par Terraform (il se trouve donc dans le fichier d'état : ne jamais le versionner).

data "azurerm_client_config" "current" {}

resource "random_string" "suffixe" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  etiquettes = merge({ projet = "intake", gere_par = "terraform" }, var.tags)

  noms = {
    gateway = "${var.prefix}-gateway"
    litellm = "${var.prefix}-litellm"
    worker  = "${var.prefix}-worker"
  }

  # Variables d'environnement lues dans Key Vault, par application. Ce sont les noms des clés des
  # fichiers .env (jamais leurs valeurs). PUBLIC_HOST, LLM_API_BASE et WORKER_URL sont fixés plus bas.
  secrets_par_app = {
    gateway = ["TELNYX_API_KEY", "TELNYX_PUBLIC_KEY", "OPENAI_API_KEY", "LLM_MODEL", "MCP_TOKEN", "LLM_API_KEY"]
    worker  = ["OPENAI_API_KEY", "LLM_MODEL"]
    litellm = ["OPENAI_API_KEY", "TELNYX_API_KEY", "LITELLM_MASTER_KEY", "LITELLM_SALT_KEY"]
  }

  # Nom du secret dans Key Vault => application et variable d'environnement.
  # Exemple : "gateway-telnyx-api-key" => { app = "gateway", env = "TELNYX_API_KEY" }
  secrets_kv = merge([
    for app, cles in local.secrets_par_app : {
      for cle in cles : "${app}-${replace(lower(cle), "_", "-")}" => { app = app, env = cle }
    }
  ]...)

  domaine_env = azurerm_container_app_environment.env.default_domain

  # Adresse publique de la passerelle : Telnyx s'y connecte (webhook et flux audio wss://…/telnyx/media).
  hote_gateway = "${local.noms.gateway}.${local.domaine_env}"

  # Adresses internes. Une application sans accès public se trouve sous « .internal. ».
  base_litellm = var.litellm_external ? "https://${local.noms.litellm}.${local.domaine_env}" : "https://${local.noms.litellm}.internal.${local.domaine_env}"
  base_worker  = "https://${local.noms.worker}.internal.${local.domaine_env}"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.prefix}"
  location = var.location
  tags     = local.etiquettes
}

# Identité partagée par les trois applications : elle lit les secrets dans Key Vault.
# Elle est créée avant les applications pour que ses droits existent quand elles démarrent.
resource "azurerm_user_assigned_identity" "apps" {
  name                = "id-${var.prefix}-apps"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = local.etiquettes
}

resource "azurerm_key_vault" "kv" {
  name                = "kv-${var.prefix}-${random_string.suffixe.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # démonstration : on veut pouvoir tout détruire

  tags = local.etiquettes
}

# Toi (ou le compte qui lance Terraform) : écrit les secrets.
resource "azurerm_role_assignment" "kv_ecriture" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Les applications : lisent les secrets, rien d'autre.
resource "azurerm_role_assignment" "kv_lecture" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.apps.principal_id
}

# Les droits Azure mettent un moment à se propager : sans pause, l'écriture d'un secret juste après échoue parfois.
resource "time_sleep" "droits_kv" {
  depends_on      = [azurerm_role_assignment.kv_ecriture, azurerm_role_assignment.kv_lecture]
  create_duration = "60s"
}

resource "azurerm_log_analytics_workspace" "logs" {
  name                = "log-${var.prefix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.etiquettes
}

resource "azurerm_container_app_environment" "env" {
  name                       = "cae-${var.prefix}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
  tags                       = local.etiquettes
}
