#!/bin/sh
# Démarrage d'une sentinelle (sentinel-1, sentinel-2, sentinel-3).
#
# Comme pour les nœuds, la config est générée une fois dans le volume : Sentinel y réécrit
# en continu son état (master courant, replicas et sentinelles connus, epoch). Après un
# redémarrage, la sentinelle repart donc du master actuel, pas de INITIAL_MASTER.
#
# Variables : REDIS_PASSWORD, NODE_NAME, INITIAL_MASTER, MASTER_NAME, QUORUM
set -eu

CONF=/data/sentinel.conf
MASTER_NAME="${MASTER_NAME:-mymaster}"
QUORUM="${QUORUM:-2}"

if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOF
port 26379
dir /data
# Noms DNS au lieu d'IP (indispensable en conteneur : les IP changent à la recréation)
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip ${NODE_NAME}
sentinel announce-port 26379
# Accès aux sentinelles protégé par le même mot de passe (exporter, redis-cli)
requirepass ${REDIS_PASSWORD}
sentinel sentinel-pass ${REDIS_PASSWORD}

sentinel monitor ${MASTER_NAME} ${INITIAL_MASTER} 6379 ${QUORUM}
sentinel auth-pass ${MASTER_NAME} ${REDIS_PASSWORD}
# Master déclaré injoignable (sdown) après 5s sans réponse
sentinel down-after-milliseconds ${MASTER_NAME} 5000
sentinel failover-timeout ${MASTER_NAME} 30000
sentinel parallel-syncs ${MASTER_NAME} 1
EOF
  echo "sentinel: configuration initiale générée (${NODE_NAME}, surveille ${INITIAL_MASTER})"
else
  sed -i -e "s|^requirepass .*|requirepass ${REDIS_PASSWORD}|" \
         -e "s|^sentinel sentinel-pass .*|sentinel sentinel-pass ${REDIS_PASSWORD}|" \
         -e "s|^sentinel auth-pass ${MASTER_NAME} .*|sentinel auth-pass ${MASTER_NAME} ${REDIS_PASSWORD}|" "$CONF"
  echo "sentinel: configuration existante réutilisée"
fi

exec docker-entrypoint.sh redis-server "$CONF" --sentinel
