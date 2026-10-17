#!/usr/bin/env bash

# example: bash rename.sh '^photo_([0-9]+)\.jpg$' 'image_{1}.jpg'

set -u

if [[ $# -ne 2 ]]; then
  printf "Usage : %s <regex_filtre> <modèle_renommage>\n" "$0" >&2
  exit 1
fi

filter=$1
template=$2

shopt -s nullglob dotglob

for file in *; do
  [[ -f $file ]] || continue

  if [[ $file =~ $filter ]]; then
    captures=("${BASH_REMATCH[@]}")
    new=$template

    for ((i = 1; i < ${#captures[@]}; i++)); do
      new=${new//\{$i\}/${captures[i]}}
    done

    [[ $new == "$file" ]] && continue

    if [[ -e $new ]]; then
      printf "Conflit : %s existe déjà, fichier ignoré.\n" "$new" >&2
      continue
    fi

    mv -- "$file" "$new" || exit 1
  fi
done