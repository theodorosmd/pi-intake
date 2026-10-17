"""Mesure ce que le proxy ajoute par appel : même question, en direct chez OpenAI puis via LiteLLM."""

import json
import statistics
import time
import urllib.request
from pathlib import Path

DOSSIER = Path(__file__).parent
ESSAIS = 5
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


def chrono(url, cle, modele):
    corps = json.dumps({"model": modele, "messages": MESSAGES}).encode()
    requete = urllib.request.Request(
        url, data=corps,
        headers={"Authorization": f"Bearer {cle}", "Content-Type": "application/json"},
    )
    debut = time.perf_counter()
    with urllib.request.urlopen(requete, timeout=60) as reponse:
        json.load(reponse)
    return (time.perf_counter() - debut) * 1000


cibles = {
    "direct OpenAI": ("https://api.openai.com/v1/chat/completions", lire(".env", "OPENAI_API_KEY"), "gpt-6-luna"),
    "via le proxy": ("http://localhost:4000/v1/chat/completions", lire("cles-virtuelles.env", "INTAKE_PROD"), "llm-agent"),
}
resultats = {}
for nom, (url, cle, modele) in cibles.items():
    temps = []
    for i in range(ESSAIS):
        temps.append(chrono(url, cle, modele))
        print(f"{nom:14s} essai {i + 1} : {temps[-1]:6.0f} ms")
    resultats[nom] = statistics.median(temps)

direct, proxy = resultats["direct OpenAI"], resultats["via le proxy"]
print(f"\nMédiane direct : {direct:.0f} ms | via le proxy : {proxy:.0f} ms | "
      f"surcoût du proxy : {proxy - direct:+.0f} ms")
print("(Les réponses du modèle varient d'un essai à l'autre : seul un écart net est significatif.)")
