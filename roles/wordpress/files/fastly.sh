#!/bin/bash
set -eu

ETCDIR=/etc/fastly

if [[ ! -d $ETCDIR || ! -w $ETCDIR ]] ; then
  echo "ERROR: $ETCDIR: Directory does not exist or is not writable" >&2
  exit 1
fi

tmpdir=$(mktemp -d)
function cleanup {
  rm -r $tmpdir
}
trap cleanup EXIT

function limit {
  echo "limit from ${1//[^A-Fa-f0-9.:\/]/} to any proto tcp"
}

function add {
  ufw $(limit $1) >/dev/null
}

function remove {
  ufw delete $(limit $1) >/dev/null
}

curl -sS -o- https://api.fastly.com/public-ip-list |
  json_xs -t none -e 'print join "\n", @{$_->{addresses}}' |
    sort -u >$tmpdir/ips

if [[ ! -s $tmpdir/ips ]] ; then
  echo "ERROR: ips: Got zero-byte file from Fastly?" >&2
  exit 2
fi

if [[ -f $ETCDIR/ips ]] ; then
  if [[ ! -r $ETCDIR/ips ]] ; then
    echo "ERROR: $ETCDIR/ips: File not readable" >&2
    exit 3
  fi

  while read -r ip ; do
    add $ip
  done < <(comm -13 $ETCDIR/ips $tmpdir/ips)

  while read -r ip ; do
    remove $ip
  done < <(comm -23 $ETCDIR/ips $tmpdir/ips)
else
  while read -r ip ; do
    add $ip
  done < $tmpdir/ips
fi

cp -f $tmpdir/ips $ETCDIR/ips
rm -f $tmpdir/ips
