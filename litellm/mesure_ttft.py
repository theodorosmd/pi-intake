"""Mesure le délai avant le premier mot de chaque modèle, via le proxy, en streaming.

Usage : python litellm/mesure_ttft.py [modele ...]   (par défaut : llm-agent llm-telnyx)
Pour tester un autre modèle, ajoute-le dans config.yaml (model_list), redémarre le proxy
(docker compose restart litellm), puis passe son nom ici. La clé maître est utilisée.
"""

import json
import statistics
import sys
import time
import urllib.request
from pathlib import Path

DOSSIER = Path(__file__).parent
ESSAIS = 8
MESSAGES = [
    {"role": "system", "content": "You are a phone intake assistant. Answer in one short sentence."},
    {"role": "user", "content": "My name is Dan Nguyen and I was rear-ended on the BQE."},
]


def lire(fichier, nom):
    return next(
        ligne.split("=", 1)[1].strip()
        for ligne in (DOSSIER / fichier).read_text().splitlines()
        if ligne.startswith(nom + "=")
    )


def mesurer(cle, modele):
    """Renvoie (délai avant le 1er mot, durée totale) en ms."""
    corps = json.dumps({"model": modele, "messages": MESSAGES, "stream": True}).encode()
    requete = urllib.request.Request(
        "http://localhost:4000/v1/chat/completions",
        data=corps,
        headers={"Authorization": f"Bearer {cle}", "Content-Type": "application/json"},
    )
    debut = time.perf_counter()
    premier = None
    with urllib.request.urlopen(requete, timeout=60) as reponse:
        for ligne in reponse:
            ligne = ligne.decode().strip()
            if not ligne.startswith("data:") or ligne.endswith("[DONE]"):
                continue
            morceau = json.loads(ligne[5:])
            if premier is None and morceau.get("choices"):
                if morceau["choices"][0].get("delta", {}).get("content"):
                    premier = time.perf_counter()
    fin = time.perf_counter()
    return ((premier or fin) - debut) * 1000, (fin - debut) * 1000


# Clé maître : les modèles de test ne sont pas dans la liste autorisée de la clé INTAKE_PROD.
cle = lire(".env", "LITELLM_MASTER_KEY")
modeles = sys.argv[1:] or ["llm-agent", "llm-telnyx"]
medianes = {}
for modele in modeles:
    premiers = []
    for i in range(ESSAIS):
        premier, total = mesurer(cle, modele)
        premiers.append(premier)
        print(f"{modele:12s} essai {i + 1} : 1er mot {premier:6.0f} ms | total {total:6.0f} ms")
    medianes[modele] = statistics.median(premiers)
    print()

print("Médiane du délai avant le premier mot :")
for modele, valeur in sorted(medianes.items(), key=lambda x: x[1]):
    print(f"  {modele:12s} {valeur:6.0f} ms")
print("(À comparer au budget : l'AI Assistant répond en ~1160 ms voix comprise.)")
