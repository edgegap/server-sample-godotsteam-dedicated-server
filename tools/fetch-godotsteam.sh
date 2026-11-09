#!/usr/bin/env bash
# Downloads the GodotSteam GDExtension add-ons this sample was tested with into addons/.
# Run from the project root (Git Bash works on Windows): ./tools/fetch-godotsteam.sh
set -euo pipefail

SERVER_VERSION="${GODOTSTEAM_SERVER_VERSION:-4.12.1}"   # GodotSteam Server (dedicated server)
CLIENT_VERSION="${GODOTSTEAM_VERSION:-4.24}"            # GodotSteam (game client)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/server.zip" \
  "https://codeberg.org/godotsteam/godotsteam-server/releases/download/v${SERVER_VERSION}-gde/godotsteam-server-${SERVER_VERSION}-gdextension-plugin-4.4.zip"
curl -fsSL -o "$tmp/client.zip" \
  "https://codeberg.org/godotsteam/godotsteam/releases/download/v${CLIENT_VERSION}-gde/godotsteam-${CLIENT_VERSION}-gdextension-plugin-4.4.zip"

rm -rf addons/godotsteam_server addons/godotsteam
unzip -q "$tmp/server.zip" -d .
unzip -q "$tmp/client.zip" -d .
echo "Installed addons/godotsteam_server (${SERVER_VERSION}) and addons/godotsteam (${CLIENT_VERSION})."
