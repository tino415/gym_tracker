#!/usr/bin/env bash
# Runs on the host: the dev container has no jq.
# Upload an app bundle to a Play track through the Google Play Developer API,
# authenticated with a service account key. Needs curl, openssl and jq.
#
#   tool/play-upload.sh <service-account.json> <package> <track> <bundle.aab> [release-notes]
#   tool/play-upload.sh --check <service-account.json> <package>
#   tool/play-upload.sh --next-code <service-account.json> <package>
#   tool/play-upload.sh --verify-signing <service-account.json> <package> <versionCode>
#
# An upload commits its release as a draft, then releases it with
# PLAY_RELEASE_STATUS (default completed) only when Play's app-signing cert
# equals the package's pin in play-app-signing.sha256; draft stops after the check.
# --check opens an edit and deletes it again: proves the account may touch the
# app without releasing anything.
# --next-code prints the highest versionCode Play knows (the edit's bundles and
# every track's releases) plus 1, through an edit it deletes again.
# --verify-signing prints Play's app-signing certs of a versionCode and fails
# when one differs from the pin.
set -euo pipefail
shopt -s inherit_errexit

api=https://androidpublisher.googleapis.com/androidpublisher/v3/applications
scope=https://www.googleapis.com/auth/androidpublisher
pins=$(dirname "${BASH_SOURCE[0]}")/play-app-signing.sha256

base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

access_token() {
  local key=$1 now header claims signing_input
  now=$(date +%s)
  header=$(jq -nc '{alg:"RS256",typ:"JWT"}' | base64url)
  claims=$(jq -nc --arg iss "$(jq -r .client_email "$key")" --arg scope "$scope" --argjson now "$now" \
    '{iss:$iss,scope:$scope,aud:"https://oauth2.googleapis.com/token",iat:$now,exp:($now+3600)}' | base64url)
  signing_input="$header.$claims"
  local signature
  signature=$(printf %s "$signing_input" | openssl dgst -sha256 -sign <(jq -r .private_key "$key") | base64url)
  curl -fsS https://oauth2.googleapis.com/token \
    -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer -d "assertion=$signing_input.$signature" | jq -r .access_token
}

call() {
  local body status
  body=$(curl -sS -w "\n%{http_code}" -H "Authorization: Bearer $token" "$@") || return 1
  status=${body##*$'\n'}
  body=${body%$'\n'*}
  [ "$status" -lt 300 ] || { echo "HTTP $status from ${*: -1}: $body" >&2; return 1; }
  printf %s "$body"
}

open_edit() { call -X POST -H 'Content-Type: application/json' -d '{}' "$api/$package/edits" | jq -r .id; }

check() {
  local edit
  edit=$(open_edit)
  call -X DELETE "$api/$package/edits/$edit"
  echo "ok: $package is reachable as $(jq -r .client_email "$key")"
}

next_code() {
  local edit bundles tracks
  edit=$(open_edit)
  bundles=$(call "$api/$package/edits/$edit/bundles") || { call -X DELETE "$api/$package/edits/$edit"; return 1; }
  tracks=$(call "$api/$package/edits/$edit/tracks") || { call -X DELETE "$api/$package/edits/$edit"; return 1; }
  call -X DELETE "$api/$package/edits/$edit"
  jq -n --argjson bundles "$bundles" --argjson tracks "$tracks" \
    '([$bundles.bundles[]?.versionCode] + [$tracks.tracks[]?.releases[]?.versionCodes[]? | tonumber]) | (max // 0) + 1'
}

upload() {
  local version status=${PLAY_RELEASE_STATUS:-completed}
  pinned_hash > /dev/null
  version=$(upload_as_draft)
  echo "committed versionCode $version to $track as a draft"
  signing_matches_pin "$version" "$(await_signing_hashes "$version")" ||
    { echo "versionCode $version stays an unreleased draft on $track" >&2; return 1; }
  if [ "$status" = draft ]; then
    echo "left versionCode $version as a draft on $track"
    return
  fi
  release "$version" "$status"
  echo "released versionCode $version to $track"
}

upload_as_draft() {
  local edit response
  edit=$(open_edit)
  response=$(call -X POST -H 'Content-Type: application/octet-stream' --data-binary "@$bundle" \
    "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/$package/edits/$edit/bundles?uploadType=media") || { echo "$response" >&2; return 1; }
  put_release "$edit" "$(jq -r .versionCode <<<"$response")" draft
  call -X POST "$api/$package/edits/$edit:commit" > /dev/null
  jq -r .versionCode <<<"$response"
}

release() {
  local edit
  edit=$(open_edit)
  put_release "$edit" "$1" "$2"
  call -X POST "$api/$package/edits/$edit:commit" > /dev/null
}

put_release() {
  local edit=$1 version=$2 status=$3
  call -X PUT -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg track "$track" --arg code "$version" --arg notes "$notes" --arg status "$status" \
      '{track:$track,releases:[{status:$status,versionCodes:[$code],releaseNotes:(if $notes == "" then [] else [{language:"en-US",text:$notes}] end)}]}')" \
    "$api/$package/edits/$edit/tracks/$track" > /dev/null
}

signing_matches_pin() {
  local version=$1 found=$2 expected line
  expected=$(pinned_hash)
  echo "pinned app-signing cert:     $expected"
  echo "Play's app-signing cert of versionCode $version:"
  while read -r line; do echo "  $line"; done <<<"${found:-none}"
  [ -n "$found" ] && ! grep -qvxF "$expected" <<<"$found"
}

pinned_hash() {
  local hash
  hash=$(awk -v package="$package" '$1 == package { print $2 }' "$pins")
  [ -n "$hash" ] || { echo "no app-signing pin for $package in $pins: refusing" >&2; return 1; }
  printf %s "$hash"
}

await_signing_hashes() {
  local version=$1 found deadline=$((SECONDS + 600))
  until found=$(signing_hashes "$version" 2> /dev/null) && [ -n "$found" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 0
    sleep 30
  done
  printf '%s\n' "$found"
}

signing_hashes() { call "$api/$package/generatedApks/$1" | jq -r '.generatedApks[]?.certificateSha256Hash'; }

if [ "$1" = --check ]; then
  key=$2 package=$3
  token=$(access_token "$key")
  check
elif [ "$1" = --next-code ]; then
  key=$2 package=$3
  token=$(access_token "$key")
  next_code
elif [ "$1" = --verify-signing ]; then
  key=$2 package=$3 version=$4
  pinned_hash > /dev/null
  token=$(access_token "$key")
  signing_matches_pin "$version" "$(signing_hashes "$version")"
else
  key=$1 package=$2 track=$3 bundle=$4 notes=${5:-}
  token=$(access_token "$key")
  upload
fi
