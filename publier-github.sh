#!/bin/bash
# Publie IPodWheel sur GitHub : depot PRIVE + release v0.1.0.
# A lancer sur ton Mac, dans le dossier IPodWheel :   bash publier-github.sh
set -e
cd "$(dirname "$0")"
REPO=IPodWheel
VERSION=$(sed -n 's/^Version: //p' control)

# 1) outil GitHub (gh) et connexion : c'est toi qui te connectes, dans ton navigateur
export PATH="/opt/local/bin:/opt/local/sbin:$PATH"     # MacPorts
if ! command -v gh >/dev/null 2>&1; then
  echo "Installation de l'outil GitHub (gh) avec MacPorts (mot de passe du Mac demande)..."
  command -v port >/dev/null 2>&1 || { echo "MacPorts introuvable dans /opt/local/bin."; exit 1; }
  sudo port -N install gh
fi
gh auth status >/dev/null 2>&1 || gh auth login --web --git-protocol https

# 2) paquet .deb (compile s'il n'existe pas encore)
DEB=$(ls -t packages/*.deb 2>/dev/null | head -1 || true)
if [ -z "$DEB" ]; then make package FINALPACKAGE=1; DEB=$(ls -t packages/*.deb | head -1); fi

# 3) zip des sources (sans les fichiers de compilation)
ZIP="/tmp/IPodWheel-$VERSION.zip"
rm -f "$ZIP"
( cd .. && zip -rq "$ZIP" IPodWheel -x "IPodWheel/.theos/*" "IPodWheel/packages/*" "IPodWheel/.git/*" "*.DS_Store" )

# 4) depot git local
[ -d .git ] || git init -q -b main
git add -A
git diff --cached --quiet || git commit -q -m "IPodWheel $VERSION"

# 5) depot PRIVE sur GitHub (cree s'il n'existe pas) + envoi
if gh repo view "$REPO" >/dev/null 2>&1; then
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "$(gh repo view "$REPO" --json url -q .url).git"
  git push -u origin main
else
  gh repo create "$REPO" --private --source=. --remote=origin --push \
    --description "Interface iPod classic a click wheel pour iPhone 4 sous iOS 6 (jailbreak, Theos)"
fi

# 6) release avec le .deb et le zip des sources
if gh release view "v$VERSION" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$DEB" "$ZIP" --clobber
else
  gh release create "v$VERSION" "$DEB" "$ZIP" --title "IPodWheel $VERSION" --notes-file RELEASE_NOTES.md
fi

echo ""
echo "Termine : $(gh repo view "$REPO" --json url -q .url)"
