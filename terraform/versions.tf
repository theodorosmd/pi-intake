terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    # À la destruction, le coffre est purgé : on peut le recréer tout de suite, sans attendre la fin de la rétention.
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}
