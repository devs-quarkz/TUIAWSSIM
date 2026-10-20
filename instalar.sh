#!/usr/bin/env bash
#
# instalar.sh — descarga TUIAWSSIM y lanza el TUI.
#
#   Desde GitHub:
#     curl -fsSL https://raw.githubusercontent.com/devs-quarkz/TUIAWSSIM/main/instalar.sh | bash
#
#   Desde el servidor del profesor (sin internet):
#     curl -fsSL http://IP_DEL_PROFESOR:8000/instalar.sh | bash -s -- --servidor http://IP_DEL_PROFESOR:8000
#
#   Con opciones:
#     ... | bash -s -- --auto --limpiar
#
set -o pipefail

REPO="devs-quarkz/TUIAWSSIM"
RAMA="main"
SERVIDOR=""
DESTINO="$HOME/TUIAWSSIM"
ARG_TUI=()

while [ $# -gt 0 ]; do
  case "$1" in
    --servidor) SERVIDOR="${2%/}"; shift 2 ;;
    --destino)  DESTINO="$2"; shift 2 ;;
    --auto|--limpiar|--ayuda|-h|--help) ARG_TUI+=("$1"); shift ;;
    *) shift ;;
  esac
done

# ── Identificar el sistema ───────────────────────────────────
case "$(uname -s)" in
  Darwin)
    SISTEMA="macOS $(sw_vers -productVersion 2>/dev/null)"
    GESTOR="brew"
    ;;
  Linux)
    if [ -r /etc/os-release ]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      SISTEMA="${PRETTY_NAME:-Linux}"
    else
      SISTEMA="Linux"
    fi
    GESTOR="apt"
    ;;
  *)
    SISTEMA="$(uname -s)"
    GESTOR="?"
    ;;
esac

printf '\n\033[1;36m  TUIAWSSIM — instalador\033[0m\n'
printf '  Sistema detectado: %s\n' "$SISTEMA"
printf '  Gestor de paquetes: %s\n\n' "$GESTOR"

case "$SISTEMA" in
  *Mint*|*Ubuntu*|*Debian*) : ;;
  macOS*) : ;;
  *) printf '\033[1;33m  Aviso: este sistema no está probado (solo Mint, Ubuntu y macOS)\033[0m\n' ;;
esac

# ── Descargar el proyecto ────────────────────────────────────
if [ -n "$SERVIDOR" ]; then
  URL="$SERVIDOR/TUIAWSSIM.tar.gz"
  printf '  Descargando del servidor del profesor:\n    %s\n' "$URL"
else
  URL="https://codeload.github.com/$REPO/tar.gz/refs/heads/$RAMA"
  printf '  Descargando de GitHub:\n    %s\n' "$URL"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! curl -fsSL "$URL" -o "$TMP/repo.tar.gz"; then
  printf '\n\033[1;31m  ✗ No pude descargar el proyecto.\033[0m\n'
  printf '  Si estás en clase sin internet, pide la dirección del servidor del profesor\n'
  printf '  y ejecuta:\n\n'
  printf '    curl -fsSL http://IP:PUERTO/instalar.sh | bash -s -- --servidor http://IP:PUERTO\n\n'
  exit 1
fi

tar -xzf "$TMP/repo.tar.gz" -C "$TMP" 2>/dev/null || { printf '  ✗ No pude descomprimir\n'; exit 1; }

# La carpeta puede llamarse TUIAWSSIM, TUIAWSSIM-main o tuiawssim
ORIGEN=""
for cand in "$TMP"/TUIAWSSIM* "$TMP"/tuiawssim* "$TMP"/*/floci-tui.sh; do
  if [ -f "$cand" ]; then ORIGEN="$cand"; break; fi
  if [ -f "$cand/floci-tui.sh" ]; then ORIGEN="$cand"; break; fi
done
[ -n "$ORIGEN" ] || ORIGEN="$(dirname "$(find "$TMP" -name floci-tui.sh -maxdepth 3 2>/dev/null | head -1)")"
if [ ! -f "$ORIGEN/floci-tui.sh" ]; then
  printf '  ✗ El paquete descargado no contiene floci-tui.sh\n'
  exit 1
fi

mkdir -p "$DESTINO"
cp -R "$ORIGEN"/. "$DESTINO"/ 2>/dev/null
chmod +x "$DESTINO"/*.sh 2>/dev/null
printf '\n\033[1;32m  ✓ Instalado en %s\033[0m\n' "$DESTINO"

# ── Lanzar ───────────────────────────────────────────────────
cd "$DESTINO" || exit 1
printf '  Lanzando el TUI…\n\n'
exec ./floci-tui.sh "${ARG_TUI[@]}"
