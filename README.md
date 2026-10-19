# pi-intake — déploiement de l'agent vocal d'accueil

Ce dépôt contient tout ce qui fait tourner l'agent sur le cluster : le chart Helm, les manifestes Kubernetes, la configuration du proxy LiteLLM et le workflow de déploiement. Le code de l'agent est dans le dépôt `intake-py`, celui du worker de résumé dans `summary-worker`.

## Ce qui tourne

Un chart Helm (`chart/`) déploie cinq éléments dans le namespace `intake` d'un cluster k3s :

- la passerelle d'appel (`intake-py`), exposée sur `intake.theappstudio.co` avec un certificat Let's Encrypt ;
- le worker de résumé (`summary-worker`) ;
- le proxy LiteLLM, par lequel passent les appels au modèle ;
- une base Postgres 16 avec l'extension pgvector (appels, dossiers, base de connaissances) ;
- une sauvegarde nocturne de la base à 3 h 30 (heure de Paris), conservée 7 jours.

Les valeurs qui changent d'un environnement à l'autre sont dans `chart/values.yaml`. Les modèles du dossier `chart/templates/` n'en contiennent aucune.

## Du commit à la production

1. **Commit sur `main` dans `intake-py`.** La CI (`.github/workflows/ci.yml`) lance `ruff`, puis toute la suite de tests sur une vraie base Postgres avec pgvector, comme en production. Une pull request subit les mêmes vérifications, mais ne publie rien.
2. **Image.** Si les vérifications passent, la CI construit l'image Docker et la publie sur GHCR (`ghcr.io/theodorosmd/intake-py`) avec une étiquette liée au commit, par exemple `sha-9bfd5a4`. Un contenu donné a une seule étiquette, pour toujours.
3. **Déploiement, déclenché à la main.** Dans ce dépôt, le workflow `deploy` (onglet Actions) demande l'étiquette à déployer. Il tourne dans l'environnement protégé `production`, ouvre un tunnel SSH vers l'API Kubernetes avec un compte de déploiement aux droits limités (`k8s/deploy-rbac.yaml`), puis exécute :

   ```
   helm upgrade --install intake ./chart -n intake --set gateway.image.tag=<étiquette> --wait --timeout 5m
   ```

   Le workflow affiche ensuite l'historique des révisions Helm.

## Revenir en arrière

Chaque déploiement crée une révision Helm. Pour revenir à la précédente :

```
helm history intake -n intake
helm rollback intake <révision> -n intake
```

On peut aussi relancer le workflow `deploy` avec l'étiquette d'une image plus ancienne.

## Secrets

Les mots de passe et clés ne sont pas dans ce dépôt. Le script `k8s/secrets.sh` crée les secrets du cluster à partir de fichiers `.env` locaux, qui sont ignorés par git.

## Limites connues

- Le proxy LiteLLM utilise l'étiquette `latest` : à épingler par digest.
- Le déploiement est volontairement manuel ; il n'y a pas de déploiement automatique après la CI.
