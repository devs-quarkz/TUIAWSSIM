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
FORZAR_DESCARGA=0
DESTINO="$HOME/TUIAWSSIM"
ARG_TUI=()

while [ $# -gt 0 ]; do
  case "$1" in
    --servidor) SERVIDOR="${2%/}"; shift 2 ;;
    --destino)  DESTINO="$2"; shift 2 ;;
    --ayuda|-h|--help) ARG_TUI+=("$1"); shift ;;
    *) ARG_TUI+=("$1"); shift ;;   # todo lo demás se le pasa al TUI
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

# ── Paquete offline: solo lo que falte, y nunca dos veces ──────────
if [ -n "$SERVIDOR" ]; then
  mkdir -p "$DESTINO/offline"

  # ¿ya está esto descargado?
  hay_herramientas() {
    [ -s "$DESTINO/offline/awscliv2.zip" ] && [ -n "$(ls "$DESTINO"/offline/paquetes/*.deb 2>/dev/null)" ]
  }
  hay_imagenes() { [ -s "$DESTINO/offline/imagenes-floci.tar.gz" ]; }

  descargar() {   # descargar <url> <destino> <etiqueta>
    local url="$1" dst="$2" eti="$3" tmp
    tmp="$(mktemp)"
    printf '  ↓ %s…\n' "$eti"
    if curl -fsSL "$url" -o "$tmp"; then
      mv -f "$tmp" "$dst"
      printf '\033[1;32m    ✓ %s\033[0m\n' "$eti"
      return 0
    fi
    rm -f "$tmp"
    printf '\033[1;33m    ! no pude bajar: %s\033[0m\n' "$eti"
    return 1
  }

  printf '\n  Comprobando el paquete del profesor…\n'

  # ¿le hace falta algo de verdad? Si ya tiene todo, no se baja nada
  falta_algo() {
    command -v docker >/dev/null 2>&1 || return 0
    command -v aws    >/dev/null 2>&1 || return 0
    command -v psql   >/dev/null 2>&1 || return 0
    return 1
  }
  faltan_imagenes() {
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0
    docker image inspect floci/floci:latest >/dev/null 2>&1 || return 0
    docker image inspect postgres:16.3-alpine >/dev/null 2>&1 || return 0
    docker image inspect alpine:3.21 >/dev/null 2>&1 || return 0
    docker image inspect public.ecr.aws/amazonlinux/amazonlinux:2023 >/dev/null 2>&1 || return 0
    return 1
  }

  # 1) herramientas: .deb (Docker, psql) + instalador de la AWS CLI
  if [ "$FORZAR_DESCARGA" = 0 ] && ! falta_algo; then
    printf '    · herramientas: ya tienes Docker, AWS CLI y psql, no bajo nada\n'
  elif [ "$FORZAR_DESCARGA" = 0 ] && hay_herramientas; then
    printf '    · herramientas: ya las tienes, no las bajo otra vez\n'
  elif curl -fsI "$SERVIDOR/herramientas.tar.gz" >/dev/null 2>&1; then
    if descargar "$SERVIDOR/herramientas.tar.gz" "$DESTINO/offline/herramientas.tar.gz" "herramientas (~170 MB)"; then
      tar -xzf "$DESTINO/offline/herramientas.tar.gz" -C "$DESTINO/offline" --strip-components=1 2>/dev/null \
        && rm -f "$DESTINO/offline/herramientas.tar.gz"
    fi
  elif curl -fsI "$SERVIDOR/offline.tar.gz" >/dev/null 2>&1; then
    if descargar "$SERVIDOR/offline.tar.gz" "$DESTINO/offline/offline.tar.gz" "paquete completo (~415 MB)"; then
      tar -xzf "$DESTINO/offline/offline.tar.gz" -C "$DESTINO/offline" --strip-components=1 2>/dev/null \
        && rm -f "$DESTINO/offline/offline.tar.gz"
    fi
  fi

  # 2) imágenes de Docker
  if [ "$FORZAR_DESCARGA" = 0 ] && ! faltan_imagenes; then
    printf '    · imágenes: ya están cargadas en Docker, no bajo nada\n'
  elif [ "$FORZAR_DESCARGA" = 0 ] && hay_imagenes; then
    printf '    · imágenes: ya las tienes, no las bajo otra vez\n'
  elif curl -fsI "$SERVIDOR/imagenes-floci.tar.gz" >/dev/null 2>&1; then
    descargar "$SERVIDOR/imagenes-floci.tar.gz" "$DESTINO/offline/imagenes-floci.tar.gz" "imágenes de Docker (~260 MB)"
  fi

  if hay_herramientas && hay_imagenes; then
    printf '\033[1;32m    ✓ Paquete offline completo (funciona sin internet)\033[0m\n'
  fi
fi
chmod +x "$DESTINO"/*.sh 2>/dev/null
printf '\n\033[1;32m  ✓ Instalado en %s\033[0m\n' "$DESTINO"

# ── Lanzar ───────────────────────────────────────────────────
cd "$DESTINO" || exit 1
# El instalador es la vía del ALUMNO: no hereda el rol que hubiera en el equipo
case " ${ARG_TUI[*]} " in
  *" --profesor "*|*" --alumno "*) : ;;
  *) ARG_TUI+=(--alumno) ;;
esac

printf '  Lanzando el TUI en modo alumno…\n'
printf '  (si eres el profesor y quieres tu menú: ./floci-tui.sh --profesor)\n\n'
exec ./floci-tui.sh "${ARG_TUI[@]}"
