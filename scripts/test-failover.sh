#!/usr/bin/env bash
# Simule la panne du master Redis et mesure la bascule.
#   1. trouve le master courant (via Sentinel)
#   2. écrit en continu à travers HAProxy (comme n8n)
#   3. arrête le master, attend l'élection d'un nouveau master
#   4. redémarre l'ancien master et vérifie qu'il revient en replica
#
# Usage : ./scripts/test-failover.sh            (moteur auto, comme setup.sh)
#         ENGINE=podman ./scripts/test-failover.sh
#         KEEP_DOWN=1 ./scripts/test-failover.sh   (laisse l'ancien master arrêté)
set -euo pipefail
cd "$(dirname "$0")/.."

ENGINE="${ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  if [[ "$(uname -s)" == Darwin ]]; then candidates=(docker podman); else candidates=(podman docker); fi
  for c in "${candidates[@]}"; do command -v "$c" >/dev/null 2>&1 && { ENGINE="$c"; break; }; done
  [[ -z "$ENGINE" ]] && { echo "Ni docker ni podman trouvé." >&2; exit 1; }
fi
dc() { "$ENGINE" compose "$@"; }
# redis-cli lancé depuis sentinel-1 (REDISCLI_AUTH déjà défini dans le conteneur)
cli() { dc exec -T sentinel-1 redis-cli --no-auth-warning "$@" 2>/dev/null | tr -d '\r'; }
current_master() { cli -h "$1" -p 26379 sentinel get-master-addr-by-name mymaster | head -n 1; }
role_of() { cli -h "$1" role | head -n 1; }
now() { date +%s.%N 2>/dev/null || date +%s; }
elapsed() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }

echo "==> Moteur : $ENGINE"
MASTER="$(current_master sentinel-1)"
[[ -z "$MASTER" ]] && { echo "Sentinel ne répond pas : stack démarrée ?" >&2; exit 1; }
echo "==> Master actuel : $MASTER"
for n in redis-1 redis-2 redis-3; do printf "    %-8s %s\n" "$n" "$(role_of "$n" || echo '?')"; done
echo "    via HAProxy : $(cli -h haproxy info replication | grep '^role')"

# Écritures continues à travers HAProxy, une toutes les 250 ms, chacune sur une connexion neuve
LOG="$(mktemp)"
dc exec -T sentinel-1 sh -c '
  i=0; while [ $i -lt 160 ]; do
    r=$(timeout 1 redis-cli --no-auth-warning -h haproxy incr failover:test 2>&1 | tr -d "\r" | tr "\n" " ")
    echo "$(date +%s) $r"; i=$((i+1)); sleep 0.25
  done' > "$LOG" 2>/dev/null &
WRITER=$!
sleep 2

echo "==> Arrêt de $MASTER"
T0="$(now)"
dc stop "$MASTER" >/dev/null 2>&1

NEW=""
for _ in $(seq 1 120); do
  NEW="$(current_master sentinel-2)"
  [[ -n "$NEW" && "$NEW" != "$MASTER" ]] && break
  sleep 0.5
done
if [[ -z "$NEW" || "$NEW" == "$MASTER" ]]; then
  echo "!! Pas de nouveau master après 60s (quorum ? logs : $ENGINE compose logs sentinel-1)" >&2
else
  echo "==> Nouveau master élu par Sentinel : $NEW (après $(elapsed "$T0")s)"
fi

# Attend que HAProxy route vers le nouveau master
for _ in $(seq 1 40); do
  [[ "$(cli -h haproxy info replication | grep '^role')" == "role:master" ]] && break
  sleep 0.5
done
echo "==> HAProxy route de nouveau vers un master (après $(elapsed "$T0")s)"

wait "$WRITER" || true
OK=$(grep -cE '^[0-9]+ [0-9]+ ?$' "$LOG" || true); TOTAL=$(grep -cE '^[0-9]+ ' "$LOG" || true)
FIRST_KO=$(grep -vE '^[0-9]+ [0-9]+ ?$' "$LOG" | head -n 1 | cut -d' ' -f1)
LAST_KO=$(grep -vE '^[0-9]+ [0-9]+ ?$' "$LOG" | tail -n 1 | cut -d' ' -f1)
echo "==> Écritures via HAProxy : $OK OK / $TOTAL ($((TOTAL - OK)) en échec)"
[[ -n "$FIRST_KO" ]] && echo "    coupure vue par un client : ~$((LAST_KO - FIRST_KO + 1))s"
echo "    compteur final : $(cli -h haproxy get failover:test)"
rm -f "$LOG"

if [[ "${KEEP_DOWN:-0}" == 1 ]]; then
  echo "==> KEEP_DOWN=1 : $MASTER reste arrêté (relancer : $ENGINE compose start $MASTER)"
  exit 0
fi

echo "==> Redémarrage de $MASTER"
dc start "$MASTER" >/dev/null 2>&1
for _ in $(seq 1 30); do [[ -n "$(role_of "$MASTER")" ]] && break; sleep 1; done
R="$(role_of "$MASTER")"
if [[ "$R" == slave ]]; then
  echo "    $MASTER est revenu en replica de $NEW : OK"
else
  echo "!! $MASTER est revenu avec le rôle '$R' (attendu : slave)" >&2
fi
dc logs --no-log-prefix "$MASTER" 2>/dev/null | grep 'redis-node:' | tail -n 1 | sed 's/^/    /'

echo
echo "État final :"
for n in redis-1 redis-2 redis-3; do printf "    %-8s %s\n" "$n" "$(role_of "$n")"; done
echo "Dashboard : https://n8n.localhost:8443/grafana/d/redis-ha"
