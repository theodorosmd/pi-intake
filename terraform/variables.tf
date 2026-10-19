variable "subscription_id" {
  description = "Identifiant de l'abonnement Azure (az account show --query id -o tsv)."
  type        = string
}

variable "location" {
  description = "Région Azure. À vérifier avant de lancer : Container Apps et le serveur Postgres B1ms doivent y être proposés pour ton abonnement."
  type        = string
  default     = "francecentral"
}

variable "prefix" {
  description = "Préfixe des noms de ressources (lettres minuscules et chiffres)."
  type        = string
  default     = "intake"
}

variable "tags" {
  description = "Étiquettes ajoutées à toutes les ressources."
  type        = map(string)
  default     = {}
}

# --- Images (mêmes dépôts que chart/values.yaml)

variable "ghcr_username" {
  description = "Compte GitHub qui possède les images privées sur GHCR."
  type        = string
  default     = "theodorosmd"
}

variable "gateway_tag" {
  type        = string
  default     = "sha-2f103d2"
  description = "Étiquette de l'image intake-py (workflow ci : sha-<commit>). Constaté le 19 octobre : l'ancienne étiquette 0.1.2 date du 18 au matin et ne contient ni le résumé post-appel, ni la base Postgres, ni la signature Telnyx, ni le RAG."
}

variable "tts_model" {
  type        = string
  default     = "openai/tts-1"
  description = "Modèle de synthèse vocale. Mesuré le 19 octobre : l'alias openai/gpt-4o-mini-tts reste sans réponse environ une requête sur deux (20 s de blocage) ; openai/tts-1 a répondu 20 fois sur 20 en 0,9 à 2,8 s."
}

variable "worker_tag" {
  type    = string
  default = "0.1.1"
}

variable "litellm_tag" {
  description = "Comme dans le chart : « latest » n'est pas épinglé, à remplacer par un digest."
  type        = string
  default     = "latest"
}

# --- Phases de déploiement (voir README.md)

variable "deploy_apps" {
  description = "false : on crée seulement l'infrastructure (coffre, base, environnement). true : on crée aussi les trois applications, une fois les secrets envoyés dans le coffre."
  type        = bool
  default     = false
}

variable "gateway_min_replicas" {
  description = "Réplicas toujours allumés pour la passerelle. Garder 1 : avec 0, le premier appel après une pause tomberait sur un démarrage à froid et le webhook Telnyx n'aurait pas de réponse à temps."
  type        = number
  default     = 1

  validation {
    condition     = var.gateway_min_replicas >= 0 && var.gateway_min_replicas <= 1
    error_message = "gateway_min_replicas vaut 0 ou 1 (le maximum est fixé à 1)."
  }
}

variable "litellm_min_replicas" {
  description = "Réplicas toujours allumés pour LiteLLM. Avec 0, le premier tour de parole d'un appel attendrait le démarrage de LiteLLM (plusieurs secondes)."
  type        = number
  default     = 1

  validation {
    condition     = var.litellm_min_replicas >= 0 && var.litellm_min_replicas <= 1
    error_message = "litellm_min_replicas vaut 0 ou 1 (le maximum est fixé à 1)."
  }
}

variable "worker_min_replicas" {
  description = "Réplicas toujours allumés pour le générateur de résumés. Garder 1 : mesuré le 19 octobre, son démarrage à froid dépasse 60 s alors que la passerelle ne lui laisse que 30 s, donc à 0 aucun résumé n'est produit."
  type        = number
  default     = 1

  validation {
    condition     = var.worker_min_replicas >= 0 && var.worker_min_replicas <= 1
    error_message = "worker_min_replicas vaut 0 ou 1 (le maximum est fixé à 1)."
  }
}

variable "litellm_external" {
  description = "true : donne à LiteLLM une adresse publique, le temps de créer les clés virtuelles avec litellm/creer_cles.py. À remettre à false ensuite."
  type        = bool
  default     = false
}

# --- Base de données

variable "postgres_sku" {
  description = "B_Standard_B1ms : le plus petit, déconseillé en production par Microsoft (crédits CPU), acceptable pour une démonstration."
  type        = string
  default     = "B_Standard_B1ms"
}

# --- Alertes de coût

variable "alert_email" {
  description = "Adresse qui reçoit les alertes de budget et de crédits CPU de la base. À mettre dans terraform.tfvars."
  type        = string
}

variable "budget_mensuel" {
  description = "Budget mensuel du groupe de ressources, dans la devise de ton abonnement. Les alertes préviennent, elles n'arrêtent rien."
  type        = number
  default     = 70
}

variable "budget_debut" {
  description = "Premier jour du mois où le budget commence (obligatoirement un 1er du mois)."
  type        = string
  default     = "2026-10-01T00:00:00Z"
}
