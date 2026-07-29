#!/bin/sh
# Bump MARKETING_VERSION in project.yml. Prints the new version.
set -eu

type="${1:-patch}"
current="$(sed -n 's/^ *MARKETING_VERSION: //p' project.yml | head -1)"
major="${current%%.*}"
rest="${current#*.}"
minor="${rest%%.*}"
patch="${rest#*.}"

case "$type" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) echo "usage: $0 [major|minor|patch]" >&2; exit 1 ;;
esac

version="${major}.${minor}.${patch}"

if sed --version >/dev/null 2>&1; then
    sed -i "s/^\( *MARKETING_VERSION: \).*/\1${version}/" project.yml
else
    sed -i '' "s/^\( *MARKETING_VERSION: \).*/\1${version}/" project.yml
fi

echo "$version"
