#!/bin/sh
# Démarrage d'un nœud Redis du groupe Sentinel (redis-1, redis-2, redis-3).
#
# La config est générée UNE fois dans le volume (/data/redis.conf), puis réutilisée :
# Sentinel la réécrit (CONFIG REWRITE) lors d'un failover pour y inscrire le nouveau rôle
# (replicaof). Un nœud redémarré reprend donc le rôle décidé par Sentinel, pas son rôle initial.
#
# Variables : REDIS_PASSWORD, NODE_NAME (= nom du service), INITIAL_MASTER (ex. redis-1)
set -eu

CONF=/data/redis.conf

if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOF
port 6379
dir /data
appendonly yes
# Bull (file n8n) : ne jamais évincer de clé
maxmemory-policy noeviction
# Annonce le nom DNS du conteneur (et pas son IP, qui change à chaque recréation)
replica-announce-ip ${NODE_NAME}
replica-announce-port 6379
requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}
EOF
  if [ "$NODE_NAME" != "$INITIAL_MASTER" ]; then
    echo "replicaof ${INITIAL_MASTER} 6379" >> "$CONF"
  fi
  echo "redis-node: configuration initiale générée (${NODE_NAME}, master initial : ${INITIAL_MASTER})"
else
  # Volume existant : on garde le rôle (réécrit par Sentinel), on resynchronise seulement le mot de passe
  sed -i -e "s|^requirepass .*|requirepass ${REDIS_PASSWORD}|" \
         -e "s|^masterauth .*|masterauth ${REDIS_PASSWORD}|" "$CONF"
  echo "redis-node: configuration existante réutilisée"
fi

# Avant de démarrer, on demande aux sentinelles qui est le master ACTUEL.
# Sans ça, un ancien master qui revient après un failover redémarre en master pendant
# quelques secondes (le temps que Sentinel le rétrograde) : 2 masters, HAProxy envoie des
# écritures aux deux, et celles faites sur l'ancien sont perdues à sa resynchronisation.
export REDISCLI_AUTH="$REDIS_PASSWORD"
CURRENT_MASTER=""
for s in ${SENTINELS:-sentinel-1 sentinel-2 sentinel-3}; do
  m=$(timeout 2 redis-cli --no-auth-warning -h "$s" -p 26379 \
        sentinel get-master-addr-by-name "${MASTER_NAME:-mymaster}" 2>/dev/null | head -n 1) || true
  case "$m" in
    ""|*[!A-Za-z0-9._-]*) ;;            # pas de réponse exploitable (sentinelle absente, erreur)
    *) CURRENT_MASTER="$m"; break ;;
  esac
done

if [ -z "$CURRENT_MASTER" ]; then
  echo "redis-node: aucune sentinelle joignable, rôle conservé depuis $CONF"
elif [ "$CURRENT_MASTER" = "$NODE_NAME" ]; then
  sed -i '/^replicaof /d' "$CONF"
  echo "redis-node: les sentinelles désignent ${NODE_NAME} comme master"
else
  sed -i '/^replicaof /d' "$CONF"
  echo "replicaof ${CURRENT_MASTER} 6379" >> "$CONF"
  echo "redis-node: master actuel = ${CURRENT_MASTER}, démarrage en replica"
fi

# docker-entrypoint.sh : chown de /data puis passage à l'utilisateur redis
exec docker-entrypoint.sh redis-server "$CONF"
