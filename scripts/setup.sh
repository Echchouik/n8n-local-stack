#!/usr/bin/env bash
# Prépare l'environnement local :
#   - macOS     : Docker Desktop
#   - Linux/WSL : Podman rootless (ou Docker)
# Étapes :
#   1. détecte le socket API du moteur, vu DEPUIS les conteneurs (pour Alloy)
#   2. crée .env à partir de .env.example avec des secrets aléatoires
#   3. génère les certificats mkcert dans nginx/certs/
# Ré-exécutable sans risque : ne régénère ni .env ni les certificats s'ils existent.
#
# Usage : ./scripts/setup.sh                 (moteur auto-détecté selon l'OS)
#         ENGINE=podman ./scripts/setup.sh   (forcer un moteur)
set -euo pipefail
cd "$(dirname "$0")/.."

# ---------- Détection moteur / OS ----------
OS="$(uname -s)"
IS_WSL=false
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=true

ENGINE="${ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  # macOS -> Docker en priorité ; Linux/WSL -> Podman en priorité
  if [[ "$OS" == Darwin ]]; then candidates=(docker podman); else candidates=(podman docker); fi
  for c in "${candidates[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then ENGINE="$c"; break; fi
  done
  [[ -z "$ENGINE" ]] && { echo "Ni docker ni podman trouvé." >&2; exit 1; }
fi
echo "==> Moteur : $ENGINE | OS : $OS | WSL : $IS_WSL"

# ---------- 1. Socket API (chemin vu par les conteneurs) ----------
if [[ "$ENGINE" == podman ]]; then
  if [[ "$OS" == Darwin ]] && ! podman machine inspect --format '{{.State}}' 2>/dev/null | grep -q running; then
    echo "La VM Podman n'est pas démarrée : podman machine start" >&2; exit 1
  fi
  # 'podman info' s'exécute côté moteur : sur macOS il renvoie le chemin DANS la VM,
  # sous Linux/WSL le chemin rootless de l'utilisateur (/run/user/<uid>/...).
  SOCKET="$(podman info --format '{{.Host.RemoteSocket.Path}}')"
  SOCKET="${SOCKET#unix://}"
  if [[ "$(podman info --format '{{.Host.RemoteSocket.Exists}}')" != "true" ]]; then
    echo "!! Socket Podman absent ($SOCKET)." >&2
    echo "   Linux/WSL : systemctl --user enable --now podman.socket" >&2
  fi
  BACKEND="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo '?')"
  [[ "$BACKEND" != netavark ]] && echo "!! Backend réseau '$BACKEND' : netavark est requis (DNS entre conteneurs, découverte des workers)." >&2
else
  if ! docker info >/dev/null 2>&1; then
    echo "Docker ne répond pas : démarre Docker Desktop (macOS/WSL) ou le service docker." >&2; exit 1
  fi
  # Docker Desktop (macOS/WSL) et Docker Engine exposent ce chemin dans le moteur
  SOCKET=/var/run/docker.sock
fi
echo "==> Socket API : $SOCKET"

# ---------- 2. Fichier .env ----------
gen() { openssl rand -hex "${1:-24}"; }

if [[ ! -f .env ]]; then
  awk -v pg="$(gen)" -v rd="$(gen)" -v key="$(gen 32)" -v gf="$(gen 12)" -v sock="$SOCKET" '
    /^POSTGRES_PASSWORD=/      { print "POSTGRES_PASSWORD=" pg; next }
    /^REDIS_PASSWORD=/         { print "REDIS_PASSWORD=" rd; next }
    /^N8N_ENCRYPTION_KEY=/     { print "N8N_ENCRYPTION_KEY=" key; next }
    /^GRAFANA_ADMIN_PASSWORD=/ { print "GRAFANA_ADMIN_PASSWORD=" gf; next }
    /^CONTAINER_SOCKET=/       { print "CONTAINER_SOCKET=" sock; next }
    { print }' .env.example > .env
  chmod 600 .env
  echo "==> .env créé avec des secrets aléatoires (mot de passe Grafana : voir GRAFANA_ADMIN_PASSWORD)"
else
  # .env existant : on ne met à jour que le socket (dépend de la machine).
  # L'ancienne variable PODMAN_SOCKET est remplacée par CONTAINER_SOCKET.
  tmp="$(mktemp)"
  awk -v sock="$SOCKET" '
    /^(PODMAN|CONTAINER)_SOCKET=/ { if (!done) print "CONTAINER_SOCKET=" sock; done=1; next }
    { print }
    END { if (!done) print "CONTAINER_SOCKET=" sock }' .env > "$tmp"
  cat "$tmp" > .env; rm -f "$tmp"
  echo "==> .env existant conservé (CONTAINER_SOCKET mis à jour)"
fi

# ---------- 3. Certificats mkcert ----------
if ! command -v mkcert >/dev/null 2>&1; then
  echo "mkcert introuvable : brew install mkcert (macOS) / sudo apt install mkcert libnss3-tools (WSL)" >&2
  exit 1
fi
if $IS_WSL && [[ -z "${CAROOT:-}" ]]; then
  echo "!! WSL : ton navigateur tourne sous Windows. Pour qu'il fasse confiance au certificat," >&2
  echo "   utilise la CA de mkcert installée côté Windows, par ex. :" >&2
  echo "   CAROOT=/mnt/c/Users/<toi>/AppData/Local/mkcert ./scripts/setup.sh" >&2
fi

CERTS=nginx/certs
mkdir -p "$CERTS"
if [[ ! -f "$CERTS/n8n.pem" ]]; then
  mkcert -install
  mkcert -cert-file "$CERTS/n8n.pem" -key-file "$CERTS/n8n-key.pem" \
    n8n.localhost localhost 127.0.0.1 ::1
fi
cp "$(mkcert -CAROOT)/rootCA.pem" "$CERTS/rootCA.pem"
# Lisible par nginx quel que soit le mapping d'UID (rootless, VM). OK pour du local.
chmod 644 "$CERTS"/*.pem
echo "==> Certificats prêts dans $CERTS/"

# ---------- Résolution de n8n.localhost ----------
if ! grep -q 'n8n.localhost' /etc/hosts 2>/dev/null; then
  echo "i  Chrome/Firefox résolvent *.localhost tout seuls. Pour Safari/curl, ajoute :"
  echo "   echo '127.0.0.1 n8n.localhost' | sudo tee -a /etc/hosts"
fi

echo
echo "Prêt. Lancement : $ENGINE compose up -d   ->  https://n8n.localhost:8443"
