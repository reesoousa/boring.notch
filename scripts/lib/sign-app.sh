# Funções de assinatura compartilhadas (use com `source`).

# Re-assina um .app inteiro com uma identidade, de dentro para fora: binários soltos,
# depois bundles (mais fundos antes), por fim o app. Mantém entitlements e flags de cada peça
# (inclusive o hardened runtime do Release). Todas as peças ficam com o mesmo Team ID — é o que
# a library validation exige para o app não cair na abertura.
# Uso: sign_app_tree <caminho.app> <identidade>
sign_app_tree() {
  local app="$1" identity="$2" f b
  _sign_one() {
    codesign --force --sign "$identity" --timestamp=none \
      --preserve-metadata=identifier,entitlements,flags,runtime "$1" 2>/dev/null \
      || { echo "✗ Falhou ao assinar $1" >&2; return 1; }
  }
  while IFS= read -r f; do
    if file -b "$f" | grep -q 'Mach-O'; then _sign_one "$f" || return 1; fi
  done < <(find "$app/Contents" -type f -perm -111 | awk -F/ '{print NF, $0}' | sort -rn | cut -d' ' -f2-)
  while IFS= read -r b; do
    _sign_one "$b" || return 1
  done < <(find "$app/Contents" -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' \) \
    | awk -F/ '{print NF, $0}' | sort -rn | cut -d' ' -f2-)
  _sign_one "$app" || return 1
  codesign --verify --deep --strict "$app"
}

# Hash SHA-1 da primeira identidade válida cujo nome contém o texto (ex.: "Apple Development").
find_identity_hash() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -v pat="$1" 'index($0, pat) { print $2; exit }'
}
