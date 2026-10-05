#!/bin/bash
# Indexa una carpeta de .deb como repo apt y lo deja con el layout que espera
# el apt de Termux: todo en binary-<arch>, sin binary-all.
#
# termux-apt-repo separa los paquetes "Architecture: all" en binary-all, pero el
# apt de Termux solo descarga binary-$ARCH. En el repo real de Termux no existe
# binary-all: ca-certificates, termux-keyring, termux-am y los demas estan dentro
# de binary-aarch64. Si se deja el repo como sale de termux-apt-repo, esos 19
# paquetes serian invisibles.
#
# Uso: mkarepo.sh <carpeta-de-debs> <salida> <dist> <comp> <arch>
set -euo pipefail

DEBS=$1; OUT=$2; DIST=$3; COMP=$4; ARCH=$5

command -v termux-apt-repo >/dev/null || {
  pip3 install --quiet --break-system-packages termux-apt-repo
}

rm -rf "$OUT"
termux-apt-repo "$DEBS" "$OUT" "$DIST" "$COMP" >/dev/null

BASE="$OUT/dists/$DIST/$COMP"
NDIRS=$(find "$BASE" -maxdepth 1 -type d -name 'binary-*' | wc -l)
echo "  termux-apt-repo creo $NDIRS directorios binary-*"

# 1) mover los _all dentro del directorio del arch
if [ -d "$BASE/binary-all" ]; then
  N=$(ls "$BASE/binary-all"/*.deb 2>/dev/null | wc -l)
  mv "$BASE/binary-all"/*.deb "$BASE/binary-$ARCH/"
  echo "  movidos $N debs arch:all a binary-$ARCH"
fi

# 2) fusionar los indices: reescribir la ruta y anadir al final
if [ -f "$BASE/binary-all/Packages" ]; then
  A=$(grep -c '^Package: ' "$BASE/binary-$ARCH/Packages")
  B=$(grep -c '^Package: ' "$BASE/binary-all/Packages")
  sed "s#binary-all/#binary-$ARCH/#g" "$BASE/binary-all/Packages" >> "$BASE/binary-$ARCH/Packages"
  echo "  indice fusionado: $A + $B = $(grep -c '^Package: ' "$BASE/binary-$ARCH/Packages")"
  rm -rf "$BASE/binary-all"
fi

# 3) reindexar los formatos comprimidos
cd "$BASE/binary-$ARCH"
rm -f Packages.gz Packages.xz
gzip -9kf Packages
xz -kf Packages
rm -f Release

# 4) Release con los checksums que apt verifica (con [trusted=yes] no se valida
#    la firma, pero si los hashes, asi que tienen que estar bien)
{
  echo "Origin: apex-linux"
  echo "Label: apex-linux"
  echo "Suite: $DIST"
  echo "Codename: $DIST"
  echo "Architectures: $ARCH"
  echo "Components: $COMP"
  echo "Date: $(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S UTC')"
  echo "Acquire-By-Hash: no"
  for H in MD5Sum SHA256; do
    echo "$H:"
    if [ "$H" = MD5Sum ]; then CMD=md5sum; else CMD=sha256sum; fi
    for F in Packages Packages.gz Packages.xz; do
      [ -f "$F" ] || continue
      echo " $($CMD "$F" | cut -d' ' -f1) $(stat -c %s "$F") $COMP/binary-$ARCH/$F"
    done
  done
} > Release

echo "  Release: $(grep -c 'binary-' Release) entradas"
echo "  total indexado: $(grep -c '^Package: ' Packages) paquetes"