"""Vérifie les virtual keys : la clé test est limitée à 10 requêtes par minute, la 11e doit être refusée."""

import json
import time
import urllib.error
import urllib.request
from pathlib import Path

PROXY = "http://localhost:4000"
DOSSIER = Path(__file__).parent


def lire(fichier, nom):
    return next(
        ligne.split("=", 1)[1].strip()
        for ligne in (DOSSIER / fichier).read_text().splitlines()
        if ligne.startswith(nom + "=")
    )


def appel(cle, chemin, corps=None, methode="POST"):
    entetes = {"Authorization": f"Bearer {cle}", "Content-Type": "application/json"}
    donnees = json.dumps(corps).encode() if corps is not None else None
    requete = urllib.request.Request(PROXY + chemin, data=donnees, headers=entetes, method=methode)
    with urllib.request.urlopen(requete, timeout=60) as reponse:
        return json.load(reponse)


cle_test = lire("cles-virtuelles.env", "INTAKE_TEST")
cle_maitre = lire(".env", "LITELLM_MASTER_KEY")
question = {"model": "llm-agent", "max_tokens": 5,
            "messages": [{"role": "user", "content": "Say OK."}]}

print("== 12 appels rapides avec la clé test (limite : 10 par minute)")
for i in range(1, 13):
    try:
        appel(cle_test, "/v1/chat/completions", question)
        print(f"   appel {i:2d} : accepté")
    except urllib.error.HTTPError as erreur:
        print(f"   appel {i:2d} : REFUSÉ, HTTP {erreur.code} : {erreur.read().decode()[:120]}")

print("== La clé test n'a pas le droit d'appeler un modèle hors de sa liste")
try:
    appel(cle_test, "/v1/chat/completions", {**question, "model": "gpt-6-luna"})
    print("   accepté (inattendu)")
except urllib.error.HTTPError as erreur:
    print(f"   REFUSÉ, HTTP {erreur.code}")

time.sleep(3)  # le proxy écrit les dépenses par paquets, on lui laisse un instant
print("== État des clés (vu avec la clé maître)")
for cle in appel(cle_maitre, "/key/list?return_full_object=true", methode="GET").get("keys", []):
    print(f"   {cle.get('key_alias')}: dépensé {cle.get('spend', 0):.4f} $ "
          f"sur {cle.get('max_budget')} $, limite {cle.get('rpm_limit')} req/min")
