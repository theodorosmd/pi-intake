#!/usr/bin/env bash
# Crée les Secrets du cluster à partir de tes fichiers .env locaux. Aucune valeur n'est écrite dans git.
# Relançable sans risque. Le mot de passe de la base n'est créé qu'une fois (le volume le garde).
set -euo pipefail
cd "$(dirname "$0")/.."
NS=intake

kubectl apply -f k8s/00-namespace.yaml

kubectl -n $NS create secret generic litellm-env --from-env-file=litellm/.env \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n $NS create secret generic worker-env --from-env-file=../summary-worker/.env \
  --dry-run=client -o yaml | kubectl apply -f -

# La passerelle : tout le .env sauf ce que le Deployment fixe lui-même
# (PUBLIC_HOST, LLM_API_BASE) et la clé LiteLLM (secret gateway-llm-key, créé après le démarrage de LiteLLM).
tmp=$(mktemp)
grep -vE '^(PUBLIC_HOST|LLM_API_BASE|LLM_API_KEY)=' ../intake-py/.env > "$tmp"
kubectl -n $NS create secret generic gateway-env --from-env-file="$tmp" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f "$tmp"

kubectl -n $NS get secret litellm-db >/dev/null 2>&1 || \
  kubectl -n $NS create secret generic litellm-db --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)"

# Mot de passe de la base de la passerelle : créé une fois, jamais affiché.
kubectl -n $NS get secret intake-db >/dev/null 2>&1 || \
  kubectl -n $NS create secret generic intake-db --from-literal=PASSWORD="$(openssl rand -hex 16)"

kubectl -n $NS create configmap litellm-config --from-file=config.yaml=litellm/config.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secrets et configuration créés dans le namespace $NS."
