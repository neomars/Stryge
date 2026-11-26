#!/usr/bin/env bash
# Assemble le paquet Debian/Ubuntu (amd64) de Stryge à partir du binaire Godot exporté (Linux x86_64, .pck embarqué).
# Utilisé par .github/workflows/build.yml ; réutilisable à la main.
#
# Usage : tools/release/build_deb.sh <binaire_exporté> <version> <dossier_de_sortie>
# Résultat : <dossier_de_sortie>/stryge_<version>_amd64.deb
set -euo pipefail

bin=${1:?binaire Linux exporté}
ver=${2:?version (ex. 0.8.0)}
out=${3:?dossier de sortie}

root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pkg="$work/stryge_${ver}_amd64"
maint="Martial Limousin <noreply@github.com>"

# --- contenu installé
install -Dm755 "$bin" "$pkg/usr/lib/stryge/stryge"
install -d -m755 "$pkg/usr/games"
ln -s ../lib/stryge/stryge "$pkg/usr/games/stryge"
install -Dm644 "$root/packaging/linux/stryge.desktop" "$pkg/usr/share/applications/stryge.desktop"
install -Dm644 "$root/icon.svg" "$pkg/usr/share/icons/hicolor/scalable/apps/stryge.svg"
doc="$pkg/usr/share/doc/stryge"
install -d -m755 "$doc"
install -m644 "$root/THIRD_PARTY_NOTICES.md" "$doc/THIRD_PARTY_NOTICES.md"

# --- copyright (format DEP-5), texte MIT repris de LICENSE
{
  cat <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Stryge
Upstream-Contact: Martial Limousin
Source: https://github.com/neomars/Stryge
Comment: Les données de cartes (IGN BD TOPO, OpenStreetMap) et les voix de synthèse
 embarquées dans l'exécutable ont leurs propres licences : voir THIRD_PARTY_NOTICES.md.

Files: *
Copyright: 2026 Martial Limousin
License: Expat

Files: usr/lib/stryge/stryge
Copyright: 2014-present Godot Engine contributors
 2007-2014 Juan Linietsky, Ariel Manzur
License: Expat
Comment: Le moteur Godot est embarqué dans l'exécutable.

License: Expat
EOF
  # corps de la licence : lignes indentées d'une espace, lignes vides remplacées par " ."
  tail -n +3 "$root/LICENSE" | sed -e 's/^$/ ./' -e 's/^\([^ ]\)/ \1/'
} > "$doc/copyright"
chmod 644 "$doc/copyright"

# --- journal des modifications
{
  echo "stryge ($ver) unstable; urgency=low"
  echo
  echo "  * Version $ver (voir https://github.com/neomars/Stryge)."
  echo
  echo " -- $maint  $(date -R)"
} | gzip -9n > "$doc/changelog.gz"
chmod 644 "$doc/changelog.gz"

# --- métadonnées
size_kib=$(du -sk "$pkg" | cut -f1)
install -d -m755 "$pkg/DEBIAN"
cat > "$pkg/DEBIAN/control" <<EOF
Package: stryge
Version: $ver
Section: games
Priority: optional
Architecture: amd64
Installed-Size: $size_kib
Depends: libc6 (>= 2.28), libgl1, libx11-6, libxcursor1, libxi6, libxinerama1, libxrandr2, libasound2t64 | libasound2, libudev1
Recommends: libpulse0, libwayland-client0
Maintainer: $maint
Homepage: https://github.com/neomars/Stryge
Description: canonnière de nuit au-dessus de Paris (jeu de tir en vue thermique)
 Stryge : depuis une canonnière, protégez les civils
 des infectés dans cinq secteurs de Paris et de la petite couronne (cartes
 IGN BD TOPO et OpenStreetMap). Rendu OpenGL (mode Compatibilité).
 .
 Paquet généré à partir de l'export Godot 4.7.2 (moteur et données embarqués
 dans un seul exécutable).
EOF
chmod 644 "$pkg/DEBIAN/control"

mkdir -p "$out"
dpkg-deb --root-owner-group --build "$pkg" "$out/stryge_${ver}_amd64.deb" >/dev/null
echo "$out/stryge_${ver}_amd64.deb"
