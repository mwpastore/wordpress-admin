#!/bin/bash

set -euo pipefail

# Create backups with permissions 0600
umask 077

BACKUP_DIR=/var/backups/mysql
RETAIN_DAYS=14
MAX_DELTA=5 # percent
SLEEP_TIME=300 # maximum backup duration in seconds

DB_HOST=localhost
DB_PORT=3306
DB_USER=root
#DB_PASS= # read from ~/.my.cnf by mysql and mysqldump

if [[ ! -d $BACKUP_DIR || ! -w $BACKUP_DIR ]] ; then
  echo "ERROR: $BACKUP_DIR: Directory not found or not writable" >&2
  exit 1
fi

declare -A DUMPFILES
while read database ; do
  if [[ -z $database ]] ; then
    continue
  fi

  DUMPFILES[$database]=
done < /etc/mysql/backup.txt

function mysql {
  command mysql --no-auto-rehash \
    --host=$DB_HOST --port=$DB_PORT \
    --user=$DB_USER \
    "$@"
}

function mysqldump {
  command mysqldump \
    --host=$DB_HOST --port=$DB_PORT \
    --user=$DB_USER \
    "$@"
}

function snapshot {
  set -e

  local source=$1
  local snapshot_db=${source}_snapshot
  local snapshot_file=$BACKUP_DIR/${source}.snapshot.sql

  mysql --execute="CREATE DATABASE IF NOT EXISTS \`$snapshot_db\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

  mysql $snapshot_db <${DUMPFILES[$source]}

  mysql --execute="UPDATE \`wp_users\` SET \`user_pass\` = '$';" $snapshot_db

  mysqldump $snapshot_db >$snapshot_file

  rm -f ${snapshot_file}.xz
  xz $snapshot_file
  chgrp users ${snapshot_file}.xz
  chmod g+r ${snapshot_file}.xz

  mysql --execute="DROP DATABASE \`$snapshot_db\`;"
}

echo "* Flushing with read lock"
mysql --execute="
FLUSH NO_WRITE_TO_BINLOG TABLES
  WITH READ LOCK
  AND DISABLE CHECKPOINT;
SELECT SLEEP($SLEEP_TIME);
  " &

waitpid=$!
sleep 10

proclist=$(mktemp)
mysql --skip-column-names --execute='SHOW PROCESSLIST;' >$proclist
declare -i sleep_id=$(awk "/SELECT SLEEP\\($SLEEP_TIME\\)/ { print \$1; exit }" $proclist)
rm -f $proclist

for database in ${!DUMPFILES[*]} ; do
  DUMPFILES[$database]=$BACKUP_DIR/${database}.$(date +"%Y%m%d.%H%M%S").sql

  echo "* Backing up $database"
  mysqldump --add-drop-table --single-transaction --routines --triggers \
    $database >${DUMPFILES[$database]}
done

echo "* Releasing read lock (ok if it says 'Lost connection')"
mysql --execute="KILL ${sleep_id};"

wait $waitpid || true

echo "* Creating portable snapshot(s)"
while read database ; do
  if [[ -z $database ]] ; then
    continue
  fi

  snapshot $database
done < /etc/mysql/snapshot.txt

for database in ${!DUMPFILES[*]} ; do
  size=$(stat -c "%s" ${DUMPFILES[$database]})
  if [[ -f $BACKUP_DIR/${database}.last_size ]] ; then
    last_size=$(cat $BACKUP_DIR/${database}.last_size)
    diff=$((size - last_size))
    if (( $(bc <<< "scale=5; (${diff#-} / $last_size * 100) > $MAX_DELTA") )) ; then
      echo "WARNING: backup of $database changed more than $MAX_DELTA%!"
      echo "  * old size: $last_size"
      echo "  * new size: $size"
    fi
  fi
  echo $size >$BACKUP_DIR/${database}.last_size

  echo "* Compressing backup file for $database"
  xz ${DUMPFILES[$database]}

  echo "* Purging old backup files for $database"
  find $BACKUP_DIR -type f -name "$database.*.sql.xz" \
    -ctime +$RETAIN_DAYS -print -exec rm -f {} \;
done
