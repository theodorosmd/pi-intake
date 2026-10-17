"""Teste le proxy LiteLLM : la liste des modèles, puis la même question à chacun, chronométrée."""

import json
import time
import urllib.request
from pathlib import Path

PROXY = "http://localhost:4000"
QUESTION = "In one short sentence, what does a personal injury law firm do?"

cle = next(
    ligne.split("=", 1)[1].strip()
    for ligne in (Path(__file__).parent / ".env").read_text().splitlines()
    if ligne.startswith("LITELLM_MASTER_KEY=")
)
entetes = {"Authorization": f"Bearer {cle}", "Content-Type": "application/json"}


def appel(chemin, corps=None):
    donnees = json.dumps(corps).encode() if corps else None
    requete = urllib.request.Request(PROXY + chemin, data=donnees, headers=entetes)
    with urllib.request.urlopen(requete, timeout=60) as reponse:
        return json.load(reponse)


print("== Modèles exposés par le proxy")
for modele in appel("/v1/models")["data"]:
    print(" -", modele["id"])

for modele in ("llm-openai", "llm-telnyx"):
    print(f"== {modele}")
    debut = time.perf_counter()
    try:
        reponse = appel(
            "/v1/chat/completions",
            {"model": modele, "messages": [{"role": "user", "content": QUESTION}]},
        )
        choix = reponse["choices"][0]
        message = choix["message"]
        texte = (message.get("content") or "").strip() or "(réponse vide)"
        usage = reponse.get("usage", {})
        detail = (
            f"fin = {choix.get('finish_reason')}, "
            f"tokens sortie = {usage.get('completion_tokens')}, "
            f"raisonnement = {'oui' if message.get('reasoning_content') else 'non'}"
        )
    except urllib.error.HTTPError as erreur:
        texte = f"ERREUR HTTP {erreur.code} : {erreur.read().decode()[:300]}"
        detail = ""
    print(f"   {texte}")
    print(f"   ({time.perf_counter() - debut:.2f} s) {detail}")
