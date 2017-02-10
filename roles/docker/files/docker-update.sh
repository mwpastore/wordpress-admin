#!/bin/bash

set -euo pipefail

mkdir -p /run/docker-update
psout=$(mktemp)
psout2=$(mktemp)
function cleanup {
  rmdir /run/docker-update 2>/dev/null
  rm -f $psout $psout2
}
trap cleanup EXIT

echo "Querying Docker..."
docker ps --filter 'Name=\.service' --format '{{.Image}}\t{{.Names}}' >$psout
images=$(awk '{ print $1 }' $psout | sort -u)
echo "Found $(echo $(wc -w <<< $images)) image(s) and $(echo $(wc -l < $psout)) service(s)!"

for image in $images ; do
  if ! docker pull $image >$psout2 2>&1 ; then
    echo "Image $image was updated by another process."
  elif grep -qs "Image is up to date" $psout2 ; then
    echo "Image $image is up to date."
  else
    echo "Image $image has been updated."
    for name in $(awk -v image=$image '$1 == image { print $2 }' $psout) ; do
      touch /run/docker-update/${name}.updated
    done
  fi
done

shopt -s nullglob
notices=(/run/docker-update/*.updated)
shopt -u nullglob

for notice in ${notices[@]+"${notices[@]}"} ; do
  name=$(basename $notice .updated)

  echo "Restarting ${name}..."
  systemctl restart $name

  rm -f $notice
done

echo "Cleaning up unused containers and dangling images..."
docker system prune -af

echo "Done!"
