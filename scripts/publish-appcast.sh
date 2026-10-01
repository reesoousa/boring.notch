#!/usr/bin/env bash
# Publica a atualização automática (Sparkle) da versão atual do projeto:
#   1. assina dist/boringCode-<versão>.dmg com a chave EdDSA do boringCode (chaveiro de login,
#      conta "boringcode", criada uma vez com generate_keys --account boringcode);
#   2. gera appcast.xml (só a versão mais nova; as notas vêm de dist/release-notes-v<versão>.md);
#   3. publica no branch gh-pages → https://reesoousa.github.io/boringCode/appcast.xml
#
# Rodar DEPOIS de criar a Release v<versão> com o DMG (o appcast aponta para o arquivo da Release).
# Uso: scripts/publish-appcast.sh            (publica)
#      scripts/publish-appcast.sh --dry-run  (só gera build.noindex/appcast/appcast.xml)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO="reesoousa/boringCode"
ACCOUNT="boringcode"
SPARKLE_BIN="build.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin"
OUT="build.noindex/appcast"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

VERSION=$(grep -m1 "MARKETING_VERSION = " boringNotch.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')
BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION = " boringNotch.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')
NAME=$(grep -m1 'static let name = ' boringNotch/components/Settings/Views/AboutView.swift | sed -E 's/.*"(.*)".*/\1/')
DMG="dist/boringCode-$VERSION.dmg"
NOTES="dist/release-notes-v$VERSION.md"
URL="https://github.com/$REPO/releases/download/v$VERSION/boringCode-$VERSION.dmg"

[[ -f "$DMG" ]] || { echo "✗ $DMG não existe (rode scripts/make-dmg.sh)"; exit 1; }
[[ -f "$NOTES" ]] || { echo "✗ $NOTES não existe"; exit 1; }
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "✗ Sparkle não baixado (compile o projeto uma vez)"; exit 1; }

echo "▸ Assinando $DMG (EdDSA, conta \"$ACCOUNT\")…"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account "$ACCOUNT" "$DMG")  # sparkle:edSignature="…" length="…"

if ! $DRY_RUN; then
  echo "▸ Conferindo se a Release tem o mesmo arquivo…"
  REMOTE_SIZE=$(curl -sIL "$URL" | awk 'tolower($1)=="content-length:"{s=$2} END{print s}' | tr -d '\r')
  LOCAL_SIZE=$(stat -f%z "$DMG")
  [[ "$REMOTE_SIZE" == "$LOCAL_SIZE" ]] || { echo "✗ A Release v$VERSION não tem este DMG ($REMOTE_SIZE ≠ $LOCAL_SIZE bytes)"; exit 1; }
fi

mkdir -p "$OUT"
# Notas em HTML para a janela do Sparkle (Markdown simples: títulos, listas, negrito, links, código).
NOTES_HTML=$(python3 - "$NOTES" <<'PY'
import html, re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
out, depth, in_code = [], 0, False
for line in lines:
    if line.startswith("```"):
        in_code = not in_code
        continue
    # Instalação e SHA-256 ficam só na página da Release: quem atualiza não precisa.
    if line.startswith("## ") and line[3:].strip() in ("Instalar", "Conferir o arquivo"):
        break
    if in_code:
        continue
    m = re.match(r"^(\s*)- (.*)", line)
    if m:
        level = len(m.group(1)) // 2 + 1
        while depth < level: out.append("<ul>"); depth += 1
        while depth > level: out.append("</ul>"); depth -= 1
        out.append(f"<li>{inline(m.group(2))}</li>")
        continue
    while depth: out.append("</ul>"); depth -= 1
    if line.startswith("## "):
        out.append(f"<h3>{inline(line[3:])}</h3>")
    elif line.strip():
        out.append(f"<p>{inline(line)}</p>")
while depth: out.append("</ul>"); depth -= 1
print("\n".join(out))
PY
)

PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>boringCode</title>
    <link>https://github.com/$REPO</link>
    <language>pt-BR</language>
    <item>
      <title>boringCode $VERSION — $NAME</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
<style>body{font:13px -apple-system,sans-serif;line-height:1.45} h3{font-size:14px;margin:14px 0 6px} ul{padding-left:20px}</style>
$NOTES_HTML
      ]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT/appcast.xml"
echo "✓ $OUT/appcast.xml ($VERSION, build $BUILD)"
$DRY_RUN && exit 0

echo "▸ Publicando no gh-pages…"
PAGES="build.noindex/gh-pages"
git worktree remove --force "$PAGES" 2>/dev/null || true
git fetch -q origin gh-pages 2>/dev/null || true
if git show-ref -q --verify refs/remotes/origin/gh-pages; then
  git worktree add -q -B gh-pages "$PAGES" origin/gh-pages
else
  git worktree add -q --orphan -b gh-pages "$PAGES"
fi
cp "$OUT/appcast.xml" "$PAGES/appcast.xml"
touch "$PAGES/.nojekyll"
cat > "$PAGES/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=https://github.com/reesoousa/boringCode/releases">
<title>boringCode</title><a href="https://github.com/reesoousa/boringCode/releases">boringCode — Releases</a>
HTML
git -C "$PAGES" add -A
git -C "$PAGES" commit -q -m "chore: appcast da versão $VERSION" || echo "  (appcast já estava publicado)"
git -C "$PAGES" push -q origin gh-pages
git worktree remove --force "$PAGES"

# Liga o GitHub Pages no gh-pages na primeira vez.
if ! gh api "repos/$REPO/pages" >/dev/null 2>&1; then
  gh api -X POST "repos/$REPO/pages" -f "source[branch]=gh-pages" -f "source[path]=/" >/dev/null
  echo "  GitHub Pages ligado (o primeiro deploy leva 1–2 min)."
fi
echo "✓ https://reesoousa.github.io/boringCode/appcast.xml"
