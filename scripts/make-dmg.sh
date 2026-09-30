#!/usr/bin/env bash
# Gera o instalador do boringCode: build Release universal (Apple Silicon + Intel), assinado com
# o certificado "Apple Development" do seu Apple ID, + DMG com atalho para Aplicativos.
# Uso: scripts/make-dmg.sh            → dist/boringCode-<versão>.dmg
#      SIGN_IDENTITY="<nome ou hash>" scripts/make-dmg.sh   (outra identidade)
#
# Sem notarização: quem receber precisa liberar uma vez em Ajustes › Privacidade e Segurança ›
# "Abrir mesmo assim" (ver docs/instalar.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# dmgbuild (versões travadas por hash) num venv próprio, fora do sistema.
VENV="$ROOT/build.noindex/dmgenv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  if command -v uv >/dev/null 2>&1; then
    uv venv -q "$VENV"
    VIRTUAL_ENV="$VENV" uv pip install -q --require-hashes -r Configuration/dmg/requirements.txt
  else
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --require-hashes -r Configuration/dmg/requirements.txt
  fi
fi
export PATH="$VENV/bin:$PATH"

source scripts/lib/sign-app.sh
IDENTITY="${SIGN_IDENTITY:-$(find_identity_hash "Apple Development")}"
if [ -z "$IDENTITY" ]; then
  cat >&2 <<'MSG'
✗ Nenhum certificado "Apple Development" encontrado.
  No Xcode: Ajustes › Contas › (seu Apple ID) › Gerenciar Certificados… › + › Apple Development.
  Depois rode este script de novo.
MSG
  exit 1
fi
IDENTITY_NAME="$(security find-identity -v -p codesigning | awk -v h="$IDENTITY" '$2 == h { sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit }')"

echo "▸ Compilando (Release, universal)…"
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath build.noindex -destination 'generic/platform=macOS' build -quiet

APP="build.noindex/Build/Products/Release/boringCode.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p dist
DMG="dist/boringCode-$VERSION.dmg"
rm -f "$DMG"

echo "▸ Assinando com \"${IDENTITY_NAME:-$IDENTITY}\"…"
sign_app_tree "$APP" "$IDENTITY"
TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
echo "  Team ID: $TEAM · $(lipo -archs "$APP/Contents/MacOS/boringCode")"
# A cópia do Release na pasta de build não é para abrir: some da lista de apps do Finder.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$ROOT/$APP" >/dev/null 2>&1 || true

echo "▸ Gerando $DMG…"
Configuration/dmg/create_dmg.sh "$APP" "$DMG" "boringCode"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
