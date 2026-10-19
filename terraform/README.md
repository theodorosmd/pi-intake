# Déploiement sur Azure (Terraform)

Décrit sur Azure ce que `chart/` installe sur k3s : la passerelle d'appel, LiteLLM, le générateur de résumés
et la base Postgres avec pgvector. Un `terraform destroy` supprime tout.

| Sur k3s (Hetzner) | Sur Azure |
|---|---|
| Deployment `intake-gateway`, Ingress, cert-manager | Container App publique (HTTPS et WebSocket, certificat géré par Azure) |
| Deployments `litellm` et `summary-worker` | Container Apps sans accès public |
| Pod `postgres` (pgvector/pgvector:pg16) + sauvegarde 3 h 30 | Azure Database for PostgreSQL 16, extension `vector`, sauvegardes automatiques (7 jours) |
| Secrets Kubernetes (`k8s/secrets.sh`) | Azure Key Vault (`terraform/secrets.sh`) |
| Secret `ghcr-pull` | Jeton GHCR en lecture seule, dans Key Vault |

## État de ce code : validé, pas encore appliqué

`terraform validate` passe (Terraform 1.16.6 et fournisseur `azurerm` 4.81.0, le 19 octobre) et `terraform plan` donne
l'infrastructure attendue. Rien n'a été appliqué : ce qui dépend d'Azure reste à vérifier.

- le volume de type « Secret » de LiteLLM (fichier de configuration), avec des secrets qui viennent de Key Vault ;
- les adresses internes `https://<app>.internal.<domaine>` entre applications ;
- la disponibilité de Container Apps et du serveur Postgres B1ms dans la région choisie (`francecentral` par défaut) ;
- un appel de plus de 4 minutes : le délai d'inactivité par défaut de l'ingress est de 4 minutes.

Le fichier `.terraform.lock.hcl`, créé par `terraform init`, se versionne avec le reste.

## Avant de commencer

- `az` (Azure CLI) connecté : `az login`, et `terraform` 1.6 ou plus récent.
- L'abonnement doit avoir le fournisseur `Microsoft.App` enregistré (celui de Container Apps). Un abonnement neuf
  ne l'a pas, et l'`apply` échoue sur l'environnement avec « MissingSubscriptionRegistration » :
  `az provider register --namespace Microsoft.App`, puis attendre que
  `az provider show --namespace Microsoft.App --query registrationState -o tsv` réponde `Registered`.
- Un compte qui peut créer des attributions de rôle (Propriétaire, ou Administrateur de l'accès utilisateur) :
  Terraform te donne le droit d'écrire dans le coffre et donne aux applications le droit de le lire.
- Un jeton GitHub **en lecture seule** (droit `read:packages`) : les images `intake-py` et `summary-worker` sont privées.
- Tes fichiers `.env` habituels (`intake-py/.env`, `summary-worker/.env`, `pi-intake/litellm/.env`).

## Mise en place

```bash
cd terraform
az login
cp terraform.tfvars.example terraform.tfvars      # y mettre l'identifiant d'abonnement et ton adresse e-mail
terraform init
terraform validate
terraform plan                                     # relis-le avant d'appliquer
```

1. **L'infrastructure** (coffre, base, environnement) : `terraform apply`. Aucune application n'est créée
   (`deploy_apps = false` par défaut), parce que leurs secrets ne sont pas encore dans le coffre.
2. **Les secrets** : `GHCR_TOKEN=<jeton> ./secrets.sh`. Il lit tes `.env`, envoie chaque valeur dans Key Vault
   sans l'afficher, et met la clé maître de LiteLLM comme clé LLM de la passerelle, **temporairement**.
3. **Les applications** : `terraform apply -var deploy_apps=true`.
4. **La clé virtuelle** (la clé maître ne doit pas rester dans la passerelle) :
   - `terraform apply -var deploy_apps=true -var litellm_external=true` donne une adresse publique à LiteLLM ;
   - depuis `litellm/`, lance `PROXY=$(cd ../terraform && terraform output -raw litellm_url) FICHIER_CLES=cles-virtuelles-azure.env python3 creer_cles.py` :
     les clés vont dans un fichier à part, pour ne pas mélanger celles d'Azure avec celles de k3s (la base de LiteLLM
     est distincte, une clé créée d'un côté n'existe pas de l'autre) ;
   - `ENV_CLES=../litellm/cles-virtuelles-azure.env ./secrets.sh --cle-llm` enregistre la clé `INTAKE_PROD` d'Azure ;
   - `terraform apply -var deploy_apps=true` referme LiteLLM. La passerelle reprend la nouvelle clé sous 30 minutes
     environ (`az containerapp revision list` puis `az containerapp revision restart` pour aller plus vite).
5. **Telnyx** : `terraform output gateway_host` donne la nouvelle adresse publique, à brancher sur le webhook
   et pour le flux audio (`wss://<adresse>/telnyx/media`). C'est la case suivante de la roadmap.

Mettre à jour une image : `terraform apply -var deploy_apps=true -var gateway_tag=<étiquette>`.
Tout supprimer : `terraform destroy` (le coffre est purgé, on peut recréer tout de suite).

## Coût et alertes

`alertes.tf` crée un budget mensuel (70 par défaut, dans la devise de l'abonnement) avec des e-mails à 50 % et 80 % de
la dépense réelle, et à 100 % de la prévision. Elles préviennent, elles n'arrêtent rien, et la dépense affichée a
jusqu'à un jour de retard. Estimation faite avec les tarifs publics de Container Apps (région East US, 18 octobre) :
environ 30 $ par mois pour les trois applications si elles restent presque inactives, et jusqu'à deux fois plus si
LiteLLM compte comme actif en permanence ; environ 15 $ pour Postgres B1ms ; Log Analytics au volume.
À vérifier dans le calculateur Azure pour la France, et sur la facture réelle après quelques jours.

Pour payer moins quand tu ne t'en sers pas :

- la base peut être arrêtée : `az postgres flexible-server stop --resource-group rg-intake --name <serveur>`
  (le nom est dans `terraform output postgres_host`, avant le premier point), et `start` pour la relancer. À l'arrêt, le calcul
  n'est plus facturé, seul le stockage l'est, mais Azure la redémarre seule au bout de 7 jours. Pendant l'arrêt,
  la passerelle ne peut ni démarrer un appel ni enregistrer ses données ;
- `terraform destroy` supprime tout et ramène la facture à zéro.

## Différences avec k3s à connaître

- **Déploiement** : Azure démarre la nouvelle version, bascule le trafic, puis arrête l'ancienne. Un appel en
  cours pendant un déploiement est coupé, comme avec `Recreate`.
- **Réplicas minimum** : les trois applications restent allumées (`gateway_min_replicas`, `litellm_min_replicas` et
  `worker_min_replicas` valent 1). Un appel ne doit jamais tomber sur une application endormie, et le 19 octobre le
  générateur de résumés a mis plus de 60 s à démarrer à froid, alors que la passerelle ne lui laisse que 30 s :
  avec `worker_min_replicas = 0`, aucun résumé n'est produit.
- **Mise à jour d'un secret** : une référence Key Vault sans version suit la dernière version, avec un délai d'environ 30 minutes.
- **`.github/workflows/deploy.yml`** ne sait déployer que sur k3s avec Helm. Le déploiement Azure se lance à la main avec Terraform.

## Limites assumées (démonstration)

- **Réseau de la base** : la règle `0.0.0.0` autorise tous les services Azure, pas seulement les tiens. La connexion
  exige TLS et le mot de passe fait 32 caractères, mais la version de production passerait par un réseau virtuel
  et un sous-réseau délégué.
- **Un seul compte pour les deux bases** : sur k3s, la base `intake` a son propre utilisateur sans accès à celle de LiteLLM.
- **L'état contient le mot de passe de la base** : le fichier `terraform.tfstate` reste local et ignoré par git
  (`.gitignore`). Pour travailler à plusieurs, il faudrait un état distant chiffré.
- **Niveau Burstable** : déconseillé en production par Microsoft (les crédits CPU peuvent s'épuiser). Une alerte e-mail
  se déclenche sous 30 crédits (`alertes.tf`).
- **LiteLLM** : l'étiquette `latest` n'est pas épinglée, comme dans le chart.
