#!/usr/bin/env bash
# Start two PostgreSQL shard nodes (:5470 shard0, :5471 shard1) with two-phase commit enabled.
# Run as postgres: sudo -u postgres bash start_shards.sh   (stop with: bash start_shards.sh stop)
BIN=/usr/lib/postgresql/16/bin; LAB=${LAB:-/tmp/tapnaira-shard-lab}
for port in 5470 5471; do $BIN/pg_ctl -D "$LAB/s$port" stop -m immediate >/dev/null 2>&1 || true; done
[ "${1:-}" = "stop" ] && exit 0
rm -rf "$LAB"; mkdir -p "$LAB"
for port in 5470 5471; do
  $BIN/initdb -D "$LAB/s$port" -U postgres --auth=trust >/dev/null
  printf "port = %s\nunix_socket_directories = '/tmp'\nlisten_addresses = 'localhost'\nmax_prepared_transactions = 20\n" $port >> "$LAB/s$port/postgresql.conf"
  $BIN/pg_ctl -D "$LAB/s$port" -l "$LAB/s$port.log" start -w >/dev/null && echo "shard on :$port up (max_prepared_transactions = 20)"
  psql -X -h /tmp -p $port -d postgres -qc "CREATE DATABASE tapnaira_shard"
done
