#!/usr/bin/env bash
# =====================================================================
# TapNaira – Portfolio 5: 3-node replication (chosen design: BOTH sync + async)
#   :5460  lagos1   PRIMARY            (Lagos data centre 1)
#   :5461  lagos2   SYNCHRONOUS standby (Lagos data centre 2)  -> RPO = 0
#   :5462  abuja    ASYNCHRONOUS standby (Abuja DR site)        -> disaster copy
# All nodes run on one machine on different ports (simulated sites).
# Run as postgres:  sudo -u postgres bash replication_lab.sh 2>&1 | tee ../evidence/replication_output.txt
# =====================================================================
set -uo pipefail
BIN=/usr/lib/postgresql/16/bin
LAB=${LAB:-/tmp/tapnaira-repl-lab}
P=5460; S=5461; A=5462
qp(){ psql -X -h /tmp -p $P -d tapnaira "$@"; }
qs(){ psql -X -h /tmp -p $S -d tapnaira "$@"; }
qa(){ psql -X -h /tmp -p $A -d tapnaira "$@"; }
step(){ echo; echo "=================================================================================="; echo "$*"; echo "=================================================================================="; }
count_transfers(){ psql -X -h /tmp -p $1 -d tapnaira -Atc "SELECT count(*) FROM wallet.txn WHERE reference LIKE 'LAB-%'"; }
xfer(){ # $1 = port, $2 = how many transfers of N100 from wallet 101 to 102
  for i in $(seq 1 $2); do echo "CALL wallet.transfer_funds('LAB-$(date +%s%N)-$i', 101, 102, 100, 0);"; done | psql -X -q -h /tmp -p $1 -d tapnaira; }

for port in $P $S $A; do $BIN/pg_ctl -D "$LAB/n$port" stop -m immediate >/dev/null 2>&1 || true; done
rm -rf "$LAB"; mkdir -p "$LAB"

step "R1. Primary lagos1 (:$P) + copy of the TapNaira database"
$BIN/initdb -D "$LAB/n$P" -U postgres --auth=trust >/dev/null
cat >> "$LAB/n$P/postgresql.conf" <<EOF
port = $P
unix_socket_directories = '/tmp'
listen_addresses = 'localhost'
wal_level = replica
max_wal_senders = 6
max_replication_slots = 6
hot_standby = on
synchronous_commit = on
synchronous_standby_names = ''
cluster_name = 'lagos1'
EOF
echo "host replication replicator 127.0.0.1/32 trust" >> "$LAB/n$P/pg_hba.conf"
$BIN/pg_ctl -D "$LAB/n$P" -l "$LAB/n$P.log" start -w >/dev/null && echo "lagos1 primary started"
psql -X -h /tmp -p $P -d postgres -qc "CREATE ROLE replicator REPLICATION LOGIN" -c "CREATE DATABASE tapnaira"
PGPASSWORD=${SRC_PGPASSWORD:-postgres} pg_dump -h localhost -p 5432 -U postgres -d tapnaira -n wallet | qp -q >/dev/null 2>&1
psql -X -h /tmp -p $P -d postgres -qc "ALTER DATABASE tapnaira SET search_path = wallet, public"   # triggers use unqualified names
qp -Atc "SELECT 'wallets: ' || count(*) || ', transactions: ' || (SELECT count(*) FROM wallet.txn) FROM wallet.wallet"
qp -Atc "SELECT 'slot ' || slot_name FROM pg_create_physical_replication_slot('lagos2')"
qp -Atc "SELECT 'slot ' || slot_name FROM pg_create_physical_replication_slot('abuja')"

step "R2. Clone two standbys with pg_basebackup -R"
for spec in "$S lagos2" "$A abuja"; do
  set -- $spec
  $BIN/pg_basebackup -h 127.0.0.1 -p $P -U replicator -D "$LAB/n$1" -R -X stream -S $2 --checkpoint=fast
  sed -i "s/^port = $P/port = $1/; s/^cluster_name = .*/cluster_name = '$2'/" "$LAB/n$1/postgresql.conf"
  $BIN/pg_ctl -D "$LAB/n$1" -l "$LAB/n$1.log" start -w >/dev/null && echo "$2 standby started on :$1"
done
qp -qc "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (lagos2)'" -c "SELECT pg_reload_conf()" >/dev/null
sleep 2

step "R3. Replication status on the primary: lagos2 = sync, abuja = async"
qp -c "SELECT application_name, state, sync_state, replay_lsn FROM pg_stat_replication ORDER BY 1"

step "R4. A transfer committed on the primary is visible on both standbys"
xfer $P 1
sleep 1
for port in $P $S $A; do echo -n ":$port lab transfers = "; count_transfers $port; done

step "R5. Standbys are read-only (a transfer on lagos2 is rejected)"
qs -c "CALL wallet.transfer_funds('LAB-ON-STANDBY', 101, 102, 100, 0);" 2>&1 | head -1

step "R6. Commit latency: 200 transfers, async-only vs sync to lagos2"
qp -qc "ALTER SYSTEM SET synchronous_standby_names = ''" -c "SELECT pg_reload_conf()" >/dev/null; sleep 1
t0=$(date +%s%N); xfer $P 200; t1=$(date +%s%N); echo "async only     : $(( (t1-t0)/1000000 )) ms"
qp -qc "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (lagos2)'" -c "SELECT pg_reload_conf()" >/dev/null; sleep 1
t0=$(date +%s%N); xfer $P 200; t1=$(date +%s%N); echo "sync to lagos2 : $(( (t1-t0)/1000000 )) ms   (same machine; real sites add network round-trip per commit)"

step "R7. Abuja link cut (abuja stopped): transfers CONTINUE because only lagos2 is synchronous"
$BIN/pg_ctl -D "$LAB/n$A" stop -m fast >/dev/null && echo "abuja DOWN (simulated network partition)"
t0=$(date +%s%N); xfer $P 50; t1=$(date +%s%N); echo "50 transfers committed in $(( (t1-t0)/1000000 )) ms with abuja down"
qp -c "SELECT application_name, sync_state FROM pg_stat_replication"

step "R8. Lagos2 ALSO down: no synchronous standby left -> commits BLOCK (consistency over availability)"
$BIN/pg_ctl -D "$LAB/n$S" stop -m fast >/dev/null && echo "lagos2 DOWN"
qp -c "CALL wallet.transfer_funds('LAB-BLOCKED', 101, 102, 100, 0);" > "$LAB/r8.txt" 2>&1 &
sleep 3
qp -Atc "SELECT '   after 3 s the transfer is still waiting: wait_event=' || wait_event FROM pg_stat_activity WHERE wait_event='SyncRep'"
qp -Atc "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event='SyncRep'" >/dev/null
wait; sed 's/^/   client saw: /' "$LAB/r8.txt"
echo "-- the customer is NOT told 'success' until a second Lagos copy exists; ops would page the on-call engineer"
$BIN/pg_ctl -D "$LAB/n$S" -l "$LAB/n$S.log" start -w >/dev/null && echo "lagos2 back up"; sleep 2
qp -c "SELECT application_name, sync_state FROM pg_stat_replication"

step "R9. DISASTER: lagos1 primary crashes. Compare the two standbys"
echo -n "lab transfers on lagos1 before crash: "; count_transfers $P
$BIN/pg_ctl -D "$LAB/n$P" stop -m immediate >/dev/null && echo "lagos1 CRASHED"
$BIN/pg_ctl -D "$LAB/n$A" -l "$LAB/n$A.log" start -w >/dev/null && echo "abuja restarted (cannot reach lagos1)"
sleep 1
echo -n "lagos2 (sync)  has: "; count_transfers $S
echo -n "abuja  (async) has: "; count_transfers $A
echo "-> lagos2 lost NOTHING (RPO = 0). abuja missed the transfers made while its link was down (RPO > 0)."

step "R10. FAILOVER to lagos2 (zero data loss), then re-point abuja at the new primary"
t0=$(date +%s%N); qs -Atc "SELECT 'pg_promote -> ' || pg_promote(wait => true)"; t1=$(date +%s%N)
echo "promotion took $(( (t1-t0)/1000000 )) ms"
qs -c "CALL wallet.transfer_funds('LAB-AFTER-FAILOVER', 101, 102, 100, 0);" && echo "new primary lagos2 accepts transfers"
qs -qc "SELECT pg_create_physical_replication_slot('abuja')" >/dev/null
sed -i "s/port=$P/port=$S/" "$LAB/n$A/postgresql.auto.conf"
echo "recovery_target_timeline = 'latest'" >> "$LAB/n$A/postgresql.auto.conf"
$BIN/pg_ctl -D "$LAB/n$A" -l "$LAB/n$A.log" restart -w >/dev/null && echo "abuja now follows lagos2"
sleep 3
echo -n "lagos2 lab transfers: "; count_transfers $S
echo -n "abuja  lab transfers: "; count_transfers $A
echo "-> abuja caught up with everything, including the transfers it missed"
qs -Atc "SELECT 'ledger check on new primary (unbalanced txns): ' || count(*) FROM (SELECT txn_id FROM wallet.ledger_entry GROUP BY txn_id HAVING sum(CASE direction WHEN 'DR' THEN amount ELSE -amount END) <> 0) x"
qs -Atc "SELECT 'wallets where balance <> ledger: ' || count(*) FROM wallet.wallet w JOIN (SELECT wallet_id, sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END) s FROM wallet.ledger_entry GROUP BY wallet_id) l USING (wallet_id) WHERE w.balance <> l.s"

step "Clean-up"
for port in $S $A; do $BIN/pg_ctl -D "$LAB/n$port" stop -m fast >/dev/null 2>&1; done; echo "lab stopped"
