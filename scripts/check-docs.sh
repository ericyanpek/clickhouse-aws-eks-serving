#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

extract_sections() {
  sed -nE 's/^#{2,3} ([0-9]+([.][0-9]+)*)[.]? .*/\1/p' "$1"
}

extract_commands() {
  awk '
    /^```(bash|hcl)$/ { in_block = 1; next }
    /^```$/ && in_block { in_block = 0; next }
    in_block { print }
  ' "$1"
}

count_pattern() {
  local pattern=$1
  local file=$2
  grep -Ec "$pattern" "$file" || true
}

check_pair_structure() {
  local zh=$1
  local en=$2
  local label

  for label in '^# ' '^## ' '^### ' '^#### ' '^```' '^- \[[ xX]\]'; do
    if [[ $(count_pattern "$label" "$zh") != $(count_pattern "$label" "$en") ]]; then
      echo "ERROR: structure count '$label' differs: $zh <-> $en" >&2
      return 1
    fi
  done
}

extract_sections README.md >"$tmpdir/sections.zh"
extract_sections README.en.md >"$tmpdir/sections.en"
if ! diff -u "$tmpdir/sections.zh" "$tmpdir/sections.en"; then
  echo "ERROR: README section numbering is not synchronized." >&2
  exit 1
fi

extract_commands README.md >"$tmpdir/commands.zh"
extract_commands README.en.md >"$tmpdir/commands.en"
if ! diff -u "$tmpdir/commands.zh" "$tmpdir/commands.en"; then
  echo "ERROR: README bash/HCL examples are not synchronized." >&2
  exit 1
fi

for file in README.md README.en.md; do
  grep -Fq '1 shard' "$file"
  grep -Fq '3 replicas' "$file"
  grep -Fq '25.3' "$file"
  grep -Fq '0.27.1' "$file"
  grep -Fq 'AUTO_APPROVE=true' "$file"
  grep -Fq 'recover-local-replica.sh' "$file"
done

grep -Fq '唯一权威' README.md
grep -Fq 'sole authoritative' README.en.md
grep -Fq 'docs/README.md' README.md
grep -Fq 'docs/README.en.md' README.en.md

while IFS= read -r zh; do
  en=${zh%.md}.en.md
  if [[ ! -f "$en" ]]; then
    echo "ERROR: missing English document for $zh: $en" >&2
    exit 1
  fi

  zh_name=$(basename "$zh")
  en_name=$(basename "$en")
  grep -Fq "**中文** · [English](./$en_name)" "$zh" || {
    echo "ERROR: missing Chinese-to-English switch in $zh" >&2
    exit 1
  }
  grep -Fq "[中文](./$zh_name) · **English**" "$en" || {
    echo "ERROR: missing English-to-Chinese switch in $en" >&2
    exit 1
  }
  check_pair_structure "$zh" "$en"
done < <(printf '%s\n' README.md; find docs -type f -name '*.md' ! -name '*.en.md' | sort)

python3 - "$PWD" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
link_re = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
errors = []

for doc in [root / "README.md", root / "README.en.md", *sorted((root / "docs").rglob("*.md"))]:
    text = doc.read_text(encoding="utf-8")
    for raw_target in link_re.findall(text):
        target = raw_target.strip().split(" ", 1)[0].strip("<>")
        if not target or target.startswith(("#", "http://", "https://", "mailto:")):
            continue
        path_text = target.split("#", 1)[0]
        if not path_text:
            continue
        resolved = (doc.parent / path_text).resolve()
        if not resolved.exists():
            errors.append(f"{doc.relative_to(root)} -> {target}")

if errors:
    print("ERROR: broken local Markdown links:", file=sys.stderr)
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    raise SystemExit(1)
PY

grep -Fq 'English: ./qps-by-query-type.en.txt' docs/perf-results/qps-by-query-type.txt
grep -Fq '中文: ./qps-by-query-type.txt' docs/perf-results/qps-by-query-type.en.txt
diff -u \
  <(grep '^clickhouse-ch' docs/perf-results/qps-by-query-type.txt) \
  <(grep '^clickhouse-ch' docs/perf-results/qps-by-query-type.en.txt)

echo "Documentation synchronization checks passed."
