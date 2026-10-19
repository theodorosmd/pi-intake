"""Crée deux virtual keys sur le proxy : « prod » et « test », chacune avec son budget et sa limite.

Une virtual key est une clé délivrée par le proxy, pas par OpenAI ni Telnyx.
Les services l'utilisent à la place de la clé maître : on peut la limiter, la suivre, la révoquer.
"""

import json
import os
import urllib.error
import urllib.request
from pathlib import Path

PROXY = os.environ.get("PROXY", "http://localhost:4000")
DOSSIER = Path(__file__).parent

cle_maitre = next(
    ligne.split("=", 1)[1].strip()
    for ligne in (DOSSIER / ".env").read_text().splitlines()
    if ligne.startswith("LITELLM_MASTER_KEY=")
)
entetes = {"Authorization": f"Bearer {cle_maitre}", "Content-Type": "application/json"}

CLES = {
    "intake-prod": {
        "models": ["llm-agent", "llm-openai", "llm-telnyx"],
        "max_budget": 20.0,         # dollars
        "budget_duration": "30d",   # le compteur repart à zéro tous les 30 jours
        "rpm_limit": 60,            # requêtes par minute
        "tpm_limit": 200_000,       # tokens par minute
    },
    "intake-test": {
        "models": ["llm-agent", "llm-openai", "llm-telnyx", "llm-panne"],
        "max_budget": 2.0,
        "budget_duration": "1d",
        "rpm_limit": 10,
        "tpm_limit": 50_000,
    },
}


def appel(chemin, corps=None, methode="POST"):
    donnees = json.dumps(corps).encode() if corps is not None else None
    requete = urllib.request.Request(PROXY + chemin, data=donnees, headers=entetes, method=methode)
    with urllib.request.urlopen(requete, timeout=30) as reponse:
        return json.load(reponse)


existantes = {c.get("key_alias") for c in appel("/key/list?return_full_object=true", methode="GET").get("keys", [])}
lignes = []
for alias, reglages in CLES.items():
    if alias in existantes:
        print(f"{alias} : existe déjà, je ne la recrée pas")
        continue
    reponse = appel("/key/generate", {"key_alias": alias, **reglages})
    lignes.append(f"{alias.upper().replace('-', '_')}={reponse['key']}")
    print(f"{alias} : créée (budget {reglages['max_budget']} $ / {reglages['budget_duration']}, "
          f"{reglages['rpm_limit']} req/min)")

if lignes:
    fichier = DOSSIER / os.environ.get("FICHIER_CLES", "cles-virtuelles.env")
    with fichier.open("a") as f:
        f.write("\n".join(lignes) + "\n")
    fichier.chmod(0o600)
    print(f"Clés écrites dans {fichier} (hors Git). Elles ne sont affichées nulle part.")
