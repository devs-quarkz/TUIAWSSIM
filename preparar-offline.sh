#!/usr/bin/env bash
#
# preparar-offline.sh — crea el paquete para hacer la práctica SIN INTERNET.
# Se ejecuta UNA vez en el equipo del profesor (que sí tiene internet) y deja
# todo en ./offline. Luego ./servir.sh lo reparte por la red local.
#
set -o pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/offline"
CACHE=/var/cache/apt/archives

msg()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; exit 1; }

[ "$(uname -s)" = "Darwin" ] && { warn "Esto se ejecuta en el equipo Linux del profesor (Mint/Ubuntu)."; exit 1; }

msg "Creando el paquete offline en $OUT"
mkdir -p "$OUT/paquetes" "$OUT"

# ── 1. Paquetes .deb (Docker, psql, unzip) con sus dependencias ─────
msg "Descargando los paquetes de Docker, psql y unzip"
if command -v apt-get >/dev/null 2>&1; then
  # sudo con contraseña por variable (para lanzarlo por SSH sin terminal)
  SUDO() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif [ -n "${SUDO_PASS:-}" ]; then printf '%s\n' "$SUDO_PASS" | sudo -S "$@" 2>/dev/null
    else sudo "$@"; fi
  }
  SUDO apt-get clean
  SUDO apt-get update -qq || warn "apt update falló; sigo con la caché que haya"
  SUDO apt-get install --download-only -y --reinstall \
      docker.io containerd docker-compose-v2 runc \
      postgresql-client postgresql-client-common unzip 2>&1 | tail -3
  cp -f "$CACHE"/*.deb "$OUT/paquetes/" 2>/dev/null
  rm -f "$OUT/paquetes"/*.deb.part 2>/dev/null
  ok "$(ls "$OUT/paquetes"/*.deb 2>/dev/null | wc -l) paquetes descargados"
else
  warn "No hay apt-get: este equipo no sirve para preparar el paquete Linux"
fi

# ── 2. Instalador de la AWS CLI v2 ─────────────────────────────────
msg "Descargando la AWS CLI v2"
ARQ="$(uname -m)"; case "$ARQ" in aarch64|arm64) A=aarch64 ;; *) A=x86_64 ;; esac
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$A.zip" -o "$OUT/awscliv2.zip" \
  && ok "AWS CLI: $(du -h "$OUT/awscliv2.zip" | cut -f1)" \
  || warn "No pude descargar la AWS CLI"

# ── 3. Imágenes de Docker ─────────────────────────────────────────
msg "Guardando las imágenes de Docker (tarda un par de minutos)"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  FALTAN=""
  for IMG in floci/floci:latest postgres:16.3-alpine alpine:3.21 public.ecr.aws/amazonlinux/amazonlinux:2023; do
    docker image inspect "$IMG" >/dev/null 2>&1 || FALTAN="$FALTAN $IMG"
  done
  if [ -n "$FALTAN" ]; then
    warn "Faltan imágenes:$FALTAN — las descargo"
    for IMG in $FALTAN; do docker pull "$IMG" >/dev/null 2>&1; done
  fi
  # La imagen de EC2 del paquete TIENE que llevar sshd y el arreglo de PAM:
  # si no, el alumno sin internet no puede entrar por SSH.
  msg "Comprobando la imagen de EC2"
  if docker run --rm public.ecr.aws/amazonlinux/amazonlinux:2023 \
       sh -c 'grep -q pam_permit /etc/pam.d/sshd && test -x /usr/sbin/sshd' 2>/dev/null; then
    ok "La imagen de EC2 ya lleva sshd y el arreglo de PAM"
  else
    warn "La imagen de EC2 no está preparada: la construyo (tarda ~1 minuto)"
    TMPD="$(mktemp -d)"
    printf '%s\n' \
      'FROM public.ecr.aws/amazonlinux/amazonlinux:2023' \
      'RUN dnf install -y openssh-server openssh-clients && dnf clean all' \
      'RUN sed -i /account/d /etc/pam.d/sshd' \
      'RUN echo account required pam_permit.so >> /etc/pam.d/sshd' > "$TMPD/Dockerfile"
    docker build -t public.ecr.aws/amazonlinux/amazonlinux:2023 -f "$TMPD/Dockerfile" "$TMPD" >/dev/null 2>&1 \
      && ok "Imagen de EC2 preparada (sshd + PAM)" \
      || warn "No pude construirla; el SSH podría fallar en los alumnos"
    rm -rf "$TMPD"
  fi

  docker save floci/floci:latest postgres:16.3-alpine alpine:3.21 \
      public.ecr.aws/amazonlinux/amazonlinux:2023 2>/dev/null | gzip > "$OUT/imagenes-floci.tar.gz"
  [ -s "$OUT/imagenes-floci.tar.gz" ] && ok "Imágenes: $(du -h "$OUT/imagenes-floci.tar.gz" | cut -f1)" \
    || warn "No pude guardar las imágenes"
else
  warn "Docker no está funcionando: no puedo guardar las imágenes"
fi

# ── 4. El propio proyecto ─────────────────────────────────────────
msg "Empaquetando el proyecto"
TMP="$(mktemp -d)"
mkdir -p "$TMP/TUIAWSSIM"
cp -R "$DIR"/. "$TMP/TUIAWSSIM"/ 2>/dev/null
rm -rf "$TMP/TUIAWSSIM/offline" "$TMP/TUIAWSSIM/offline.tar.gz" "$TMP/TUIAWSSIM/TUIAWSSIM.tar.gz" "$TMP/TUIAWSSIM/index.html" 2>/dev/null
tar -czf "$OUT/TUIAWSSIM.tar.gz" -C "$TMP" TUIAWSSIM
rm -rf "$TMP"
ok "Proyecto: $(du -h "$OUT/TUIAWSSIM.tar.gz" | cut -f1)"

# ── 5. Manifiesto ─────────────────────────────────────────────────
{
  echo "TUIAWSSIM — paquete para clase sin internet"
  echo "Generado: $(date)"
  echo "Equipo:   $(hostname) · $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}") · $(uname -m)"
  echo
  echo "Contenido:"
  du -sh "$OUT"/* 2>/dev/null | sed 's/^/  /'
  echo
  echo "Para repartirlo:  ./servir.sh"
  echo "  (levanta una página con el instalador y los enlaces)"
} > "$OUT/MANIFIESTO.txt"

# ── 6. Un único fichero para que el alumno lo baje de una vez ─────
msg "Empaquetando todo en un solo fichero (offline.tar.gz)"
tar -czf "$DIR/offline.tar.gz" -C "$DIR" offline
ok "offline.tar.gz: $(du -h "$DIR/offline.tar.gz" | cut -f1)"

echo
msg "Paquete listo: $OUT"
du -sh "$OUT" | sed 's/^/  total: /'
echo
echo "  Ahora reparte con:   ./servir.sh"
