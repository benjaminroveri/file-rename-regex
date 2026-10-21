#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage:\n  %s [--order=name|update|create] <folder> <filter> <template> [<filter> <template> ...]\n' "$0" >&2
  printf '  %s [--order=name|update|create] <folder> <sample.json>\n' "$0" >&2
  printf 'JSON sample mode reads the inputs array. Templates accept {1}, $1, $file_index, and $parent_folder_name placeholders.\n' >&2
}

order=name
if [[ ${1:-} == --order=* ]]; then
  order=${1#--order=}
  case $order in
    name|update|create) ;;
    *)
      printf 'Invalid order "%s"; choose name, update, or create.\n' "$order" >&2
      usage
      exit 1
      ;;
  esac
  shift
fi

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

for argument in "$@"; do
  if [[ $argument == --order=* ]]; then
    printf 'The --order option must be the first argument.\n' >&2
    usage
    exit 1
  fi
done

cleanup() {
  [[ -z ${sample_data:-} ]] || rm -f -- "$sample_data"
  [[ -z ${sorted_files:-} ]] || rm -f -- "$sorted_files"
  [[ -z ${result_data:-} ]] || rm -f -- "$result_data"
}
trap cleanup EXIT

folder=$1
shift

if [[ ! -d $folder ]]; then
  printf 'Folder does not exist: %s\n' "$folder" >&2
  exit 1
fi
folder=$(cd -- "$folder" && pwd -P)
parent_folder_name=$(basename -- "$folder")

if [[ $# -eq 1 && $1 == *.json ]]; then
  sample_file=$1
  if [[ $sample_file != */* && $sample_file != *\\* ]]; then
    script_folder=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    if [[ -f $folder/$sample_file ]]; then
      sample_file=$folder/$sample_file
    elif [[ -f $script_folder/$sample_file ]]; then
      sample_file=$script_folder/$sample_file
    fi
  fi
  if [[ ! -f $sample_file ]]; then
    printf 'JSON config not found: %s (checked target folder and script folder).\n' "$1" >&2
    exit 1
  fi
  shift

  sample_data=$(mktemp)
  perl -MJSON::PP -e '
    use strict;
    use warnings;
    local $/;
    my $sample = decode_json(<>);
    my $inputs = ref($sample) eq "HASH" ? $sample->{inputs} : $sample;
    die "JSON must contain an inputs array\n" unless ref($inputs) eq "ARRAY";
    for my $step (@$inputs) {
      die "Each input must be an object\n" unless ref($step) eq "HASH";
      my %filters = map { /^filter-regex-(\d+)$/ ? ($1 => $_) : () } keys %$step;
      my @indexes = sort { $a <=> $b } keys %filters;
      die "Each input needs matching filter-regex-N and rename-template-N fields\n"
        unless @indexes && !grep { !exists $step->{"rename-template-$_"} } @indexes;
      for my $index (@indexes) {
        print $step->{$filters{$index}}, "\0", $step->{"rename-template-$index"}, "\0";
      }
    }
  ' "$sample_file" >"$sample_data" || {
    printf 'Unable to read sample inputs from %s.\n' "$sample_file" >&2
    exit 1
  }
  mapfile -d '' -t arguments <"$sample_data"
  filters_and_templates=("${arguments[@]}")
else
  if [[ $# -lt 2 || $(($# % 2)) -ne 0 ]]; then
    usage
    exit 1
  fi
  filters_and_templates=("$@")
fi

if ((${#filters_and_templates[@]} == 0 || ${#filters_and_templates[@]} % 2 != 0)); then
  printf 'Provide at least one complete filter/template pair.\n' >&2
  usage
  exit 1
fi

perl -e '
  use strict;
  use warnings;
  while (@ARGV) {
    my ($filter) = splice @ARGV, 0, 2;
    $filter =~ s{^/(.*)/([dgimsuvy]*)$}{$1};
    my $pattern = eval { qr/$filter/ };
    die "Invalid regular expression: $@" if $@;
  }
' "${filters_and_templates[@]}"

shopt -s nullglob dotglob
files=("$folder"/*)
if [[ $order == create ]]; then
  keyed_files=()
  for file in "${files[@]}"; do
    [[ -f $file ]] || continue
    if creation_time=$(stat -c '%W' -- "$file" 2>/dev/null); then
      :
    elif creation_time=$(stat -f '%B' "$file" 2>/dev/null); then
      :
    else
      printf 'Cannot read creation time for %s.\n' "$file" >&2
      exit 1
    fi
    if [[ ! $creation_time =~ ^[0-9]+$ || $creation_time -eq 0 ]]; then
      printf 'Creation time is unavailable for %s.\n' "$file" >&2
      exit 1
    fi
    keyed_files+=("$creation_time" "$file")
  done
  sorted_files=$(mktemp)
  perl -e '
    use strict;
    use warnings;
    my @records;
    while (@ARGV) {
      push @records, [shift @ARGV, shift @ARGV];
    }
    print $_->[1], "\0" for sort {
      $a->[0] <=> $b->[0] || $a->[1] cmp $b->[1]
    } @records;
  ' "${keyed_files[@]}" >"$sorted_files"
  mapfile -d '' -t files <"$sorted_files"
elif [[ $order == update ]]; then
  sorted_files=$(mktemp)
  perl -e '
    use strict;
    use warnings;
    my %mtime;
    for my $file (@ARGV) {
      my @details = stat($file);
      die "Cannot read modification time for $file\n" unless @details;
      $mtime{$file} = $details[9];
    }
    print $_, "\0" for sort {
      $mtime{$a} <=> $mtime{$b} || $a cmp $b
    } @ARGV;
  ' "${files[@]}" >"$sorted_files"
  mapfile -d '' -t files <"$sorted_files"
elif [[ $order == name ]]; then
  sorted_files=$(mktemp)
  perl -e 'print $_, "\0" for sort @ARGV' "${files[@]}" >"$sorted_files"
  mapfile -d '' -t files <"$sorted_files"
fi
timestamp=$(date '+%Y%m%d-%H%M%S')
output_folder=$folder/file-rename-regex-$timestamp
if [[ -e $output_folder ]]; then
  printf 'Output folder already exists: %s\n' "$output_folder" >&2
  exit 1
fi
mkdir -- "$output_folder"
printf 'Output folder: %s\n' "$output_folder"

file_index=1
for file in "${files[@]}"; do
  [[ -f $file ]] || continue
  basename=${file##*/}
  result_data=$(mktemp)
  perl -e '
      use strict;
      use warnings;
      my $name = shift @ARGV;
      my $file_index = shift @ARGV;
      my $parent_folder_name = shift @ARGV;
      my $matched = 0;
      while (@ARGV) {
        my ($filter, $template) = splice @ARGV, 0, 2;
        my $flags = "";
        if ($filter =~ m{^/(.*)/([dgimsuvy]*)$}) {
          ($filter, $flags) = ($1, $2);
        }
        my $pattern = eval { qr/(?$flags:$filter)/ };
        die "Invalid regular expression: $@" if $@;
        if ($name =~ $pattern) {
          $matched = 1;
          my @captures = map {
            $-[$_] < 0 ? "" : substr($name, $-[$_], $+[$_] - $-[$_])
          } 0 .. $#-;
          $template =~ s/(\$parent_folder_name|\$file_index|\{(\d+)\}|\$(\d+))/do {
            my ($token, $brace_index, $dollar_index) = ($1, $2, $3);
            if ($token eq q{$parent_folder_name}) {
              $parent_folder_name;
            } elsif ($token eq q{$file_index}) {
              $file_index;
            } else {
              my $index = defined $brace_index ? $brace_index : $dollar_index;
              $index < @captures ? $captures[$index] : $token;
            }
          }/gex;
          $name =~ s/$pattern/$template/;
        }
      }
      print $name, "\0", $matched, "\0";
    ' "$basename" "$file_index" "$parent_folder_name" "${filters_and_templates[@]}" >"$result_data" || {
      printf 'Could not transform filename: %s\n' "$basename" >&2
      exit 1
    }
  mapfile -d '' -t result <"$result_data"
  rm -f -- "$result_data"
  result_data=
  new_name=${result[0]}
  matched=${result[1]}
  if [[ $matched == 1 ]]; then
    file_index=$((file_index + 1))
  fi

  if [[ -z $new_name || $new_name == . || $new_name == .. || $new_name == */* || $new_name == *\\* ]]; then
    printf 'Invalid output filename for %s; skipped.\n' "$basename" >&2
    continue
  fi

  target=$output_folder/$new_name
  if [[ -e $target ]]; then
    printf 'Conflict: %s already exists in output; skipped.\n' "$new_name" >&2
    continue
  fi

  cp -- "$file" "$target"
  printf '%s -> %s\n' "$basename" "$new_name"
done
