#!/usr/bin/env bash
# Envoie les valeurs de tes fichiers .env dans Key Vault. Équivalent de k8s/secrets.sh, pour Azure.
# Aucune valeur n'est affichée ni passée en argument de commande : elle transite par un fichier temporaire
# (lisible par toi seul, supprimé à la fin). Relançable sans risque.
#
#   ./secrets.sh              envoie tout ; la clé LLM de la passerelle est d'abord la clé maître (temporaire)
#   ./secrets.sh --cle-llm    remplace-la par la clé virtuelle INTAKE_PROD (litellm/cles-virtuelles.env)
#
# Pour le jeton GHCR : GHCR_TOKEN=… ./secrets.sh   (jeton en lecture seule, droit read:packages)
set -euo pipefail
cd "$(dirname "$0")"

# Où se trouvent tes fichiers .env (par défaut, les dépôts frères de pi-intake).
ENV_GATEWAY="${ENV_GATEWAY:-../../intake-py/.env}"
ENV_WORKER="${ENV_WORKER:-../../summary-worker/.env}"
ENV_LITELLM="${ENV_LITELLM:-../litellm/.env}"
ENV_CLES="${ENV_CLES:-../litellm/cles-virtuelles.env}"

KV=$(terraform output -raw key_vault_name)

umask 077
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Écrit dans $tmp la valeur de la clé $2 du fichier $1. Échoue si elle manque.
lire() {
  local ligne
  ligne=$(grep -E "^$2=" "$1" | head -1) || { echo "Clé $2 absente de $1" >&2; return 1; }
  printf '%s' "${ligne#*=}" > "$tmp"
}

# Envoie le contenu de $tmp dans le secret $1.
pousser() {
  az keyvault secret set --vault-name "$KV" --name "$1" --file "$tmp" --output none
}

# envoyer <application> <fichier> <clé>... : un secret par clé, nommé comme dans main.tf.
envoyer() {
  local app=$1 fichier=$2 cle
  shift 2
  for cle in "$@"; do
    lire "$fichier" "$cle"
    pousser "$app-$(echo "$cle" | tr 'A-Z_' 'a-z-')"
    echo "  $app / $cle"
  done
}

if [ "${1:-}" = "--cle-llm" ]; then
  lire "$ENV_CLES" INTAKE_PROD
  pousser gateway-llm-api-key
  echo "Clé virtuelle INTAKE_PROD enregistrée. Les applications la reprennent sous 30 minutes environ,"
  echo "ou tout de suite avec : az containerapp revision restart (voir README.md)."
  exit 0
fi

echo "Key Vault : $KV"

envoyer gateway "$ENV_GATEWAY" TELNYX_API_KEY TELNYX_PUBLIC_KEY OPENAI_API_KEY LLM_MODEL MCP_TOKEN
envoyer worker  "$ENV_WORKER"  OPENAI_API_KEY LLM_MODEL
envoyer litellm "$ENV_LITELLM" OPENAI_API_KEY TELNYX_API_KEY LITELLM_MASTER_KEY LITELLM_SALT_KEY

# Clé LLM de la passerelle : les clés virtuelles n'existent qu'une fois LiteLLM démarré sur Azure.
# On met donc la clé maître pour le premier démarrage, puis ./secrets.sh --cle-llm la remplace.
if ! az keyvault secret show --vault-name "$KV" --name gateway-llm-api-key --query name -o tsv >/dev/null 2>&1; then
  lire "$ENV_LITELLM" LITELLM_MASTER_KEY
  pousser gateway-llm-api-key
  echo "  gateway / LLM_API_KEY (clé maître, TEMPORAIRE : à remplacer par ./secrets.sh --cle-llm)"
fi

# Jeton GHCR : les images sont privées.
if [ -n "${GHCR_TOKEN:-}" ]; then
  printf '%s' "$GHCR_TOKEN" > "$tmp"
  pousser ghcr-token
  echo "  ghcr-token"
elif ! az keyvault secret show --vault-name "$KV" --name ghcr-token --query name -o tsv >/dev/null 2>&1; then
  echo "Il manque le jeton GHCR. Relance avec : GHCR_TOKEN=… ./secrets.sh" >&2
  exit 1
fi

echo "Terminé."
