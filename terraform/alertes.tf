# Alertes de coût et de santé de la base. Elles préviennent par e-mail : aucune ne coupe quoi que ce soit.

# Budget mensuel du groupe de ressources. Azure met à jour la dépense avec un retard pouvant aller jusqu'à un jour.
resource "azurerm_consumption_budget_resource_group" "budget" {
  name              = "budget-${var.prefix}"
  resource_group_id = azurerm_resource_group.rg.id

  amount     = var.budget_mensuel
  time_grain = "Monthly"

  time_period {
    start_date = var.budget_debut
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  # Prévision : prévient avant que le budget ne soit atteint, d'après le rythme de dépense.
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }
}

resource "azurerm_monitor_action_group" "alertes" {
  name                = "ag-${var.prefix}"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "intake"
  tags                = local.etiquettes

  email_receiver {
    name          = "proprietaire"
    email_address = var.alert_email
  }
}

# Niveau Burstable : quand les crédits CPU sont épuisés, la base ralentit fortement, voire devient injoignable.
resource "azurerm_monitor_metric_alert" "credits_cpu" {
  name                = "credits-cpu-${var.prefix}"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_postgresql_flexible_server.db.id]
  description         = "Crédits CPU de la base presque épuisés (niveau Burstable)."
  severity            = 2
  frequency           = "PT15M"
  window_size         = "PT30M"
  tags                = local.etiquettes

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_credits_remaining"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 30
  }

  action {
    action_group_id = azurerm_monitor_action_group.alertes.id
  }
}
