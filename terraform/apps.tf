# Les trois applications, équivalent des Deployments du chart. Elles ne sont créées qu'avec deploy_apps = true :
# leurs secrets doivent déjà être dans Key Vault (voir secrets.sh), sinon Azure refuse de créer la révision.
#
# Différences avec k3s :
# - Pas de stratégie « Recreate » : en mode de révision unique, Azure démarre la nouvelle version, bascule le
#   trafic, puis arrête l'ancienne. Un appel en cours pendant un déploiement est coupé, comme avant.
# - Toujours 1 réplica minimum (un appel ne doit jamais tomber sur une application endormie) et 1 maximum
#   pour la passerelle (l'état d'un appel vit dans la mémoire du processus).
# - Les services internes s'appellent par HTTPS sur leur adresse « .internal. » (pas de port 4000 ni 8000).

locals {
  secrets_gateway = { for k, v in local.secrets_kv : k => v if v.app == "gateway" }
  secrets_worker  = { for k, v in local.secrets_kv : k => v if v.app == "worker" }
  secrets_litellm = { for k, v in local.secrets_kv : k => v if v.app == "litellm" }

  # Adresse (sans version) d'un secret dans Key Vault : l'application suit la dernière version, avec un délai d'environ 30 minutes.
  uri_secret = { for k, v in local.secrets_kv : k => "${azurerm_key_vault.kv.vault_uri}secrets/${k}" }
}

# ---------------------------------------------------------------- Passerelle d'appel (seule application publique)

resource "azurerm_container_app" "gateway" {
  count = var.deploy_apps ? 1 : 0

  name                         = local.noms.gateway
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  tags                         = local.etiquettes

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }

  registry {
    server               = "ghcr.io"
    username             = var.ghcr_username
    password_secret_name = "ghcr-token"
  }

  secret {
    name                = "ghcr-token"
    identity            = azurerm_user_assigned_identity.apps.id
    key_vault_secret_id = "${azurerm_key_vault.kv.vault_uri}secrets/ghcr-token"
  }

  secret {
    name                = azurerm_key_vault_secret.url_intake.name
    identity            = azurerm_user_assigned_identity.apps.id
    key_vault_secret_id = azurerm_key_vault_secret.url_intake.versionless_id
  }

  dynamic "secret" {
    for_each = local.secrets_gateway
    content {
      name                = secret.key
      identity            = azurerm_user_assigned_identity.apps.id
      key_vault_secret_id = local.uri_secret[secret.key]
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto" # HTTP et WebSocket (flux audio de Telnyx sur /telnyx/media)

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.gateway_min_replicas
    max_replicas = 1

    container {
      name   = "gateway"
      image  = "ghcr.io/${var.ghcr_username}/intake-py:${var.gateway_tag}"
      cpu    = 0.5
      memory = "1Gi" # mesuré ~300 Mi ; 0,5 vCPU / 1 Gi est la plus petite combinaison confortable

      env {
        name  = "PUBLIC_HOST"
        value = local.hote_gateway
      }
      env {
        name  = "LLM_API_BASE"
        value = local.base_litellm
      }
      env {
        name  = "WORKER_URL"
        value = local.base_worker
      }
      env {
        name  = "TTS_MODEL"
        value = var.tts_model
      }
      env {
        name        = "DATABASE_URL"
        secret_name = azurerm_key_vault_secret.url_intake.name
      }

      dynamic "env" {
        for_each = local.secrets_gateway
        content {
          name        = env.value.env
          secret_name = env.key
        }
      }

      readiness_probe {
        transport        = "HTTP"
        port             = 8000
        path             = "/health"
        interval_seconds = 10
      }

      liveness_probe {
        transport        = "HTTP"
        port             = 8000
        path             = "/health"
        interval_seconds = 20
      }
    }
  }

  depends_on = [
    time_sleep.droits_kv,
    azurerm_postgresql_flexible_server_configuration.extensions,
    azurerm_postgresql_flexible_server_firewall_rule.services_azure,
    azurerm_container_app.litellm,
    azurerm_container_app.worker,
  ]
}

# ---------------------------------------------------------------- Proxy LiteLLM (interne, sauf pendant la création des clés)

resource "azurerm_container_app" "litellm" {
  count = var.deploy_apps ? 1 : 0

  name                         = local.noms.litellm
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  tags                         = local.etiquettes

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }

  secret {
    name                = azurerm_key_vault_secret.url_litellm.name
    identity            = azurerm_user_assigned_identity.apps.id
    key_vault_secret_id = azurerm_key_vault_secret.url_litellm.versionless_id
  }

  dynamic "secret" {
    for_each = local.secrets_litellm
    content {
      name                = secret.key
      identity            = azurerm_user_assigned_identity.apps.id
      key_vault_secret_id = local.uri_secret[secret.key]
    }
  }

  # La configuration (litellm/config.yaml) ne contient aucune clé : elle lit des variables d'environnement.
  # Elle est montée comme un fichier, avec le même contenu que le ConfigMap du cluster.
  secret {
    name  = "litellm-config"
    value = file("${path.module}/../litellm/config.yaml")
  }

  ingress {
    external_enabled = var.litellm_external
    target_port      = 4000
    transport        = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.litellm_min_replicas
    max_replicas = 1

    # Un volume de type « Secret » expose chaque secret de l'application comme un fichier du même nom.
    volume {
      name         = "config"
      storage_type = "Secret"
    }

    container {
      name   = "litellm"
      image  = "docker.litellm.ai/berriai/litellm:${var.litellm_tag}"
      cpu    = 0.5
      memory = "1Gi" # mesuré ~590-656 Mi
      args   = ["--config", "/mnt/config/litellm-config"]

      env {
        name        = "DATABASE_URL"
        secret_name = azurerm_key_vault_secret.url_litellm.name
      }

      dynamic "env" {
        for_each = local.secrets_litellm
        content {
          name        = env.value.env
          secret_name = env.key
        }
      }

      volume_mounts {
        name = "config"
        path = "/mnt/config"
      }

      # Azure limite à 10 échecs : 30 s de délai initial + 10 × 15 s laissent environ 3 min pour les migrations du premier démarrage.
      startup_probe {
        transport               = "HTTP"
        port                    = 4000
        path                    = "/health/liveliness"
        interval_seconds        = 15
        failure_count_threshold = 10
        initial_delay           = 30
      }

      readiness_probe {
        transport        = "HTTP"
        port             = 4000
        path             = "/health/readiness"
        interval_seconds = 10
      }

      liveness_probe {
        transport        = "HTTP"
        port             = 4000
        path             = "/health/liveliness"
        interval_seconds = 20
      }
    }
  }

  depends_on = [
    time_sleep.droits_kv,
    azurerm_postgresql_flexible_server_firewall_rule.services_azure,
  ]
}

# ---------------------------------------------------------------- Générateur de résumés (interne)

resource "azurerm_container_app" "worker" {
  count = var.deploy_apps ? 1 : 0

  name                         = local.noms.worker
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  tags                         = local.etiquettes

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apps.id]
  }

  registry {
    server               = "ghcr.io"
    username             = var.ghcr_username
    password_secret_name = "ghcr-token"
  }

  secret {
    name                = "ghcr-token"
    identity            = azurerm_user_assigned_identity.apps.id
    key_vault_secret_id = "${azurerm_key_vault.kv.vault_uri}secrets/ghcr-token"
  }

  dynamic "secret" {
    for_each = local.secrets_worker
    content {
      name                = secret.key
      identity            = azurerm_user_assigned_identity.apps.id
      key_vault_secret_id = local.uri_secret[secret.key]
    }
  }

  ingress {
    external_enabled = false
    target_port      = 8000
    transport        = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.worker_min_replicas
    max_replicas = 1

    container {
      name   = "summary-worker"
      image  = "ghcr.io/${var.ghcr_username}/summary-worker:${var.worker_tag}"
      cpu    = 0.25
      memory = "0.5Gi" # mesuré ~213-231 Mi

      dynamic "env" {
        for_each = local.secrets_worker
        content {
          name        = env.value.env
          secret_name = env.key
        }
      }

      readiness_probe {
        transport        = "HTTP"
        port             = 8000
        path             = "/health"
        interval_seconds = 10
      }

      liveness_probe {
        transport        = "HTTP"
        port             = 8000
        path             = "/health"
        interval_seconds = 20
      }
    }
  }

  depends_on = [time_sleep.droits_kv]
}
