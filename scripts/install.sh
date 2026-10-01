#!/usr/bin/env bash
# Instala (ou atualiza) o boringCode a partir da Release mais recente do GitHub — sem compilar.
#
#   curl -fsSL https://raw.githubusercontent.com/reesoousa/boringCode/HEAD/scripts/install.sh | bash
#
# Opções (depois de `bash -s --` quando vier pelo curl):
#   --version X.Y.Z   instala essa versão em vez da mais recente
#   --no-open         só instala, não abre o app
#   --uninstall       remove o app e os hooks do Claude Code/Codex (com backup dos ajustes)
# BORINGCODE_DIR=<pasta> instala/procura só nessa pasta (padrão: /Applications ou ~/Applications).
#
# Usa só o que vem no macOS (curl, hdiutil, plutil, codesign, osascript): roda num Mac recém-formatado
# e por agentes de IA, sem perguntas. Confere o SHA-256 que o GitHub publica para o DMG e a assinatura
# do app antes de instalar. Instala em /Applications (ou ~/Applications se não tiver permissão).
set -euo pipefail

REPO="reesoousa/boringCode"
APP="boringCode.app"
BUNDLE_ID="com.reesoousa.boringcode"
SUPPORT="$HOME/Library/Application Support/boringCode"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  cat <<'TXT'
Instala ou atualiza o boringCode a partir da Release mais recente (sem compilar).
  curl -fsSL https://raw.githubusercontent.com/reesoousa/boringCode/HEAD/scripts/install.sh | bash
  … | bash -s -- --version 0.5.0   instala essa versão
  … | bash -s -- --no-open         só instala, não abre o app
  … | bash -s -- --uninstall       remove o app e os hooks do Claude Code/Codex
TXT
}
say()  { printf '▸ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

VERSION=""
OPEN=true
UNINSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2#v}"; shift 2 ;;
    --no-open) OPEN=false; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Opção desconhecida: $1 (use --help)" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "O boringCode é um app de Mac."

# Onde está instalado (pelo bundle ID, para nunca apagar outro app com o mesmo nome).
SEARCH_DIRS=(/Applications "$HOME/Applications")
[[ -n "${BORINGCODE_DIR:-}" ]] && SEARCH_DIRS=("${BORINGCODE_DIR%/}")

installed_app() {
  local dir
  for dir in "${SEARCH_DIRS[@]}"; do
    if [[ -d "$dir/$APP" ]] && [[ "$(defaults read "$dir/$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" == "$BUNDLE_ID" ]]; then
      echo "$dir/$APP"
      return
    fi
  done
}

quit_app() {
  pgrep -qx boringCode || return 0
  say "Fechando o boringCode…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 20); do pgrep -qx boringCode || return 0; sleep 0.5; done
  pkill -x boringCode 2>/dev/null || true
  sleep 1
}

# ---------------------------------------------------------------------------------------------
# Desinstalar
# ---------------------------------------------------------------------------------------------
if $UNINSTALL; then
  quit_app
  # Tira primeiro as entradas dos ajustes dos agentes: sem o script, o Claude Code/Codex mostrariam
  # erro a cada evento. Só mexe nas entradas do boringCode; guarda uma cópia antes.
  for file in "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json"; do
    [[ -f "$file" ]] && grep -q "boringCode/bin/boringcode-hook" "$file" || continue
    cp "$file" "$file.boringcode-backup.$(date +%Y%m%d%H%M%S)"
    osascript -l JavaScript - "$file" <<'JXA' >/dev/null
ObjC.import('Foundation')
function run(argv) {
  const path = argv[0]
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js
  const settings = JSON.parse(text)
  const hooks = settings.hooks || {}
  const ours = g => (g.hooks || []).some(h => String(h.command || '').includes('boringCode/bin/boringcode-hook'))
  for (const event of Object.keys(hooks)) {
    const rest = (hooks[event] || []).filter(g => !ours(g))
    if (rest.length) hooks[event] = rest; else delete hooks[event]
  }
  if (Object.keys(hooks).length) settings.hooks = hooks; else delete settings.hooks
  $(JSON.stringify(settings, null, 2) + '\n').writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)
}
JXA
    ok "Hooks do boringCode removidos de ${file/#$HOME/~}"
  done
  rm -rf "$SUPPORT/bin"
  if app_path=$(installed_app) && [[ -n "$app_path" ]]; then
    "$LSREGISTER" -u "$app_path" >/dev/null 2>&1 || true
    rm -rf "$app_path"
    ok "App removido de ${app_path/#$HOME/~}"
  else
    ok "O app já não estava instalado"
  fi
  echo "  Seus ajustes ficaram guardados, caso você instale de novo."
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# Instalar / atualizar
# ---------------------------------------------------------------------------------------------
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
(( MACOS_MAJOR >= 14 )) || fail "Precisa do macOS 14 (Sonoma) ou mais novo — este Mac tem $(sw_vers -productVersion)."

TMP=$(mktemp -d -t boringcode-install)
MOUNT="$TMP/mnt"
cleanup() {
  [[ -d "$MOUNT" ]] && hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

say "Procurando a versão ${VERSION:-mais recente}…"
if [[ -n "$VERSION" ]]; then
  API="https://api.github.com/repos/$REPO/releases/tags/v$VERSION"
  KEY_PREFIX=""
else
  # A lista inclui pré-releases (as versões ainda não notarizadas saem assim); a primeira é a mais nova.
  API="https://api.github.com/repos/$REPO/releases?per_page=1"
  KEY_PREFIX="0."
fi
curl -fsSL -H "Accept: application/vnd.github+json" "$API" -o "$TMP/release.json" \
  || fail "Não consegui falar com o GitHub (sem internet ou versão inexistente)."

json() { plutil -extract "$KEY_PREFIX$1" raw -o - "$TMP/release.json" 2>/dev/null; }
TAG=$(json tag_name) || fail "Nenhuma Release encontrada."
COUNT=$(json assets || echo 0)
DMG_URL=""; DIGEST=""; DMG_NAME=""
for (( i = 0; i < COUNT; i++ )); do
  name=$(json "assets.$i.name") || continue
  if [[ "$name" == boringCode-*.dmg ]]; then
    DMG_NAME="$name"
    DMG_URL=$(json "assets.$i.browser_download_url")
    DIGEST=$(json "assets.$i.digest" || true)
    break
  fi
done
[[ -n "$DMG_URL" ]] || fail "A Release $TAG não tem o DMG."

if current=$(installed_app) && [[ -n "$current" ]]; then
  have=$(defaults read "$current/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
  say "Atualizando a versão $have instalada em ${current%/*} para ${TAG#v}…"
else
  say "Instalando o boringCode ${TAG#v}…"
fi

say "Baixando $DMG_NAME…"
curl -fL --progress-bar "$DMG_URL" -o "$TMP/$DMG_NAME" || fail "O download falhou."

if [[ "$DIGEST" == sha256:* ]]; then
  [[ "$(shasum -a 256 "$TMP/$DMG_NAME" | cut -d' ' -f1)" == "${DIGEST#sha256:}" ]] \
    || fail "O arquivo baixado não confere com o SHA-256 da Release. Nada foi instalado."
  ok "SHA-256 confere"
fi

mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$TMP/$DMG_NAME" \
  || fail "Não consegui abrir o DMG."
[[ -d "$MOUNT/$APP" ]] || fail "O DMG não tem o $APP."
codesign --verify --deep --strict "$MOUNT/$APP" 2>/dev/null || fail "A assinatura do app não confere. Nada foi instalado."
ok "Assinatura confere"

# Mantém onde já estava; senão /Applications, ou ~/Applications se não der para escrever lá.
DEST_DIR="${SEARCH_DIRS[0]}"
if [[ -n "${current:-}" ]]; then
  DEST_DIR="${current%/*}"
elif [[ -n "${BORINGCODE_DIR:-}" ]]; then
  mkdir -p "$DEST_DIR"
elif [[ ! -w "$DEST_DIR" ]]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi
[[ -w "$DEST_DIR" ]] || fail "Sem permissão para escrever em $DEST_DIR."
if [[ -e "$DEST_DIR/$APP" ]] && [[ "$(defaults read "$DEST_DIR/$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$BUNDLE_ID" ]]; then
  fail "Já existe outro app chamado $APP em $DEST_DIR (não é o boringCode). Remova ou renomeie antes."
fi

quit_app
rm -rf "$DEST_DIR/$APP"
ditto "$MOUNT/$APP" "$DEST_DIR/$APP"
hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
"$LSREGISTER" -f "$DEST_DIR/$APP" >/dev/null 2>&1 || true
ok "boringCode ${TAG#v} instalado em ${DEST_DIR/#$HOME/~}/$APP"

if $OPEN; then
  open "$DEST_DIR/$APP"
  ok "Aberto. Na primeira vez, as boas-vindas perguntam quais recursos usar e pedem as permissões do macOS."
fi
echo "  As próximas versões chegam sozinhas pelo próprio app (barra de menus › Verificar atualizações…)."
