#!/bin/bash
set -e
source /opt/deploy-actions/config.env
VAULT_ARG="$1"
SECRET_NAME="${2:-github-pat}"
PAT=""

# Fetch PAT from Key Vault if vault name provided
if [ -n "$VAULT_ARG" ]; then
  TOKEN=$(curl -s 'http://169.254.169.254/metadata/identity/oauth2/token?resource=https://vault.azure.net&api-version=2018-02-01' -H Metadata:true | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"//;s/"//')
  PAT=$(curl -s "https://${VAULT_ARG}.vault.azure.net/secrets/${SECRET_NAME}?api-version=7.4" -H "Authorization: Bearer ${TOKEN}" | grep -o '"value":"[^"]*"' | sed 's/"value":"//;s/"//')
fi

# Clone each repo from the list
while IFS='|' read -r visibility url target; do
  [ -z "$url" ] && continue
  if [ -d "$target" ]; then
    echo "Skipping $url (target $target already exists)"
    continue
  fi
  if [ "$visibility" = "private" ] && [ -n "$PAT" ]; then
    AUTH_URL=$(echo "$url" | sed "s|https://|https://x-access-token:${PAT}@|")
    sudo -u $DEPLOY_USER git clone "$AUTH_URL" "$target"
  else
    sudo -u $DEPLOY_USER git clone "$url" "$target"
  fi
done < /opt/deploy-actions/repos.txt
