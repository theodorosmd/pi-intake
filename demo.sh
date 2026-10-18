#!/usr/bin/env bash
# Démo de bout en bout, à lancer juste après un appel de test :
#   1. ce que l'agent a fait pendant l'appel (logs du pod, noms et numéros masqués)
#   2. ce que le cabinet en voit depuis Claude Code, via le serveur MCP pi-intake
# Usage : ./demo.sh [minutes]   (fenêtre de logs, 15 par défaut)
# Prérequis : kubectl qui atteint le cluster, et le serveur MCP pi-intake ajouté à Claude Code.
set -euo pipefail
cd "$(dirname "$0")"   # le serveur MCP pi-intake est déclaré pour ce dossier

MINUTES="${1:-15}"
GRAS=$'\e[1m'; BLEU=$'\e[34m'; VERT=$'\e[32m'; GRIS=$'\e[90m'; FIN=$'\e[0m'

titre() { printf '\n%s%s━━ %s ━━%s\n\n' "$GRAS" "$BLEU" "$1" "$FIN"; sleep 1; }

titre "1. L'appel, vu par le serveur (noms et numéros masqués)"
kubectl -n intake logs deploy/intake-gateway --since="${MINUTES}m" \
  | { grep -E "APPELANT :|AGENT :|Dossier .* enregistre|Consultation (reservee|deplacee)|Resume de l'appel|BILAN LATENCE" || echo "Aucun appel dans les ${MINUTES} dernières minutes."; } \
  | sed -E "s/^INFO: +//" \
  | while IFS= read -r ligne; do
      case "$ligne" in
        APPELANT*) printf '  %s\n' "$ligne" ;;
        AGENT*)    printf '  %s%s%s\n' "$VERT" "$ligne" "$FIN" ;;
        *)         printf '  %s%s%s\n' "$GRIS" "$ligne" "$FIN" ;;
      esac
      sleep 0.15
    done

titre "2. Le cabinet interroge l'agent depuis Claude Code (MCP)"
QUESTION="Use the pi-intake tools to list today's intake cases, the call summaries and the booked consultations. Answer in a short table, then one sentence on what the firm should do next."
printf '  %s> %s%s\n\n' "$GRAS" "$QUESTION" "$FIN"
printf '  %s(Claude appelle les outils pi-intake…)%s\n\n' "$GRIS" "$FIN"
claude -p "$QUESTION" --allowedTools "mcp__pi-intake"

titre "Fin de la démo"
