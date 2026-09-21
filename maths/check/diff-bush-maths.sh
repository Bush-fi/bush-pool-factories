#!/usr/bin/env bash
# Reviewer helper: shows how a factory's math-implementations differ from the corresponding bush-maths modules,
# ignoring import lines. Behavioural equivalence is established by `npm run maths:check` (both must reproduce the
# same generated test data exactly); this is for eyeballing the source.
#
#   pvt/math-check/diff-bush-maths.sh <factory>            e.g. weighted-pool-factory
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
factory=${1:?usage: diff-bush-maths.sh <factory>}
impl="$repo/pkg/$factory/math-implementations"
[ -d "$impl" ] || { echo "no math-implementations in pkg/$factory" >&2; exit 1; }

strip() { grep -vE '^\s*(import |from .* import|use |pub use |export \* from|} from)' "$1" | grep -vE '^\s*(//|#|\*|/\*|""")' | grep -vE '^\s*$' ; }

for lang in typescript python rust; do
  [ -d "$impl/$lang" ] || continue
  echo "== $lang"
  find "$impl/$lang" -type f \( -name '*.ts' -o -name '*.py' -o -name '*.rs' \) -not -path '*/target/*' -not -path '*/bin/*' -not -name 'index.ts' -not -name 'math_check.py' -not -name 'lib.rs' | sort | while read -r f; do
    name=$(basename "$f")
    match=$(find "$repo/bush-maths/$lang/src" -name "$name" | head -1)
    if [ -z "$match" ]; then
      # bush-maths names pool classes <thing>.py / <thing>_pool.rs and hooks live in <thing>/mod.rs; try the stem.
      ext=${name##*.}; stem=${name%.*}; stem=${stem%_pool}; stem=${stem%_hook}
      match=$(find "$repo/bush-maths/$lang/src" \( -name "${stem}.${ext}" -o -path "*/${stem}/mod.rs" -o -name "${stem}_pool.${ext}" \) | head -1)
    fi
    if [ -z "$match" ]; then echo "  $name: no counterpart in bush-maths (new maths)"; continue; fi
    if diff -q <(strip "$f") <(strip "$match") >/dev/null; then
      echo "  $name: identical to ${match#$repo/} (ignoring imports)"
    else
      echo "  $name: differs from ${match#$repo/}:"
      diff <(strip "$f") <(strip "$match") | head -40 | sed 's/^/    /'
    fi
  done
done
