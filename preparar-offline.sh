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

# Solo para decidir si descargamos o reutilizamos lo que ya hay
tiene_red() {
  [ "${FORZAR_DESCARGA:-0}" = 1 ] && return 0
  local u
  for u in https://awscli.amazonaws.com https://github.com https://deb.debian.org https://registry-1.docker.io; do
    curl -fsS -m 4 -o /dev/null "$u" 2>/dev/null && return 0
  done
  return 1
}

# Caché fuera del proyecto: sobrevive a borrar ~/TUIAWSSIM y evita volver a bajar
# La caché va en el home del usuario REAL (aunque el script corra con sudo)
if [ -n "${TUIAWSSIM_CACHE:-}" ]; then
  CACHE_DIR="$TUIAWSSIM_CACHE"
elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  CACHE_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.cache/tuiawssim"
else
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tuiawssim"
fi
mkdir -p "$CACHE_DIR/paquetes" 2>/dev/null
# Guarda en la caché SOLO si mejora lo que ya hay (nunca la encoge)
# ¿el tar de herramientas trae los .deb? (sin tubería: con pipefail falla)
tiene_debs_dentro() {
  local lista
  lista="$(mktemp)"
  tar -tzf "$1" 2>/dev/null > "$lista" || true
  grep -q 'paquetes/.*\.deb' "$lista" 2>/dev/null
  local r=$?
  rm -f "$lista"
  return $r
}

guardar_cache() {
  local src="$1" dst="$CACHE_DIR/$(basename "$1")"
  [ -f "$src" ] || return 0
  if [ -f "$dst" ] && [ "$(stat -c %s "$dst" 2>/dev/null || echo 0)" -ge "$(stat -c %s "$src" 2>/dev/null || echo 0)" ]; then
    return 0
  fi
  cp -f "$src" "$dst" 2>/dev/null
}

msg "Creando el paquete offline en $OUT"
mkdir -p "$OUT/paquetes" "$OUT"

# ── 1. Paquetes .deb (Docker, psql, unzip) con sus dependencias ─────
msg "Paquetes de Docker, psql y unzip"
if [ "$(ls "$OUT/paquetes"/*.deb 2>/dev/null | wc -l)" -ge 5 ]; then
  cp -f "$OUT/paquetes"/*.deb "$CACHE_DIR/paquetes/" 2>/dev/null
  ok "ya están en offline/paquetes ($(ls "$OUT/paquetes"/*.deb | wc -l) .deb): no descargo nada"
elif [ "$(ls "$CACHE_DIR/paquetes"/*.deb 2>/dev/null | wc -l)" -ge 5 ]; then
  cp -f "$CACHE_DIR/paquetes"/*.deb "$OUT/paquetes/" 2>/dev/null
  ok "reutilizados de la caché ($(ls "$OUT/paquetes"/*.deb | wc -l) .deb): no descargo nada"
elif [ -s "$CACHE_DIR/herramientas.tar.gz" ] && \
     tiene_debs_dentro "$CACHE_DIR/herramientas.tar.gz"; then
  tar -xzf "$CACHE_DIR/herramientas.tar.gz" -C "$OUT" --strip-components=1 2>/dev/null
  ok "reutilizados de la caché ($(ls "$OUT/paquetes"/*.deb 2>/dev/null | wc -l) .deb): no descargo nada"
elif ! command -v apt-get >/dev/null 2>&1; then
  warn "No hay apt-get: este equipo no puede preparar los paquetes Linux"
elif ! tiene_red; then
  warn "Sin internet y sin paquetes en offline/paquetes."
  warn "Ejecútalo una vez donde haya red, o copia offline/paquetes de otro equipo."
else
  # sudo con contraseña por variable (para lanzarlo por SSH sin terminal)
  SUDO() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif [ -n "${SUDO_PASS:-}" ]; then printf '%s\n' "$SUDO_PASS" | sudo -S "$@" 2>/dev/null
    else sudo "$@"; fi
  }
  SUDO apt-get update -qq || warn "apt update falló; sigo con la caché que haya"
  SUDO apt-get install --download-only -y --reinstall \
      docker.io containerd runc \
      postgresql-client postgresql-client-common unzip 2>&1 | tail -3
  cp -f "$CACHE"/*.deb "$OUT/paquetes/" 2>/dev/null
  rm -f "$OUT/paquetes"/*.deb.part 2>/dev/null
  cp -f "$OUT/paquetes"/*.deb "$CACHE_DIR/paquetes/" 2>/dev/null
  ok "$(ls "$OUT/paquetes"/*.deb 2>/dev/null | wc -l) paquetes descargados (guardados en la caché)"
fi

# ── 2. Instalador de la AWS CLI v2 ─────────────────────────────────
msg "Instalador de la AWS CLI v2"
ARQ="$(uname -m)"; case "$ARQ" in aarch64|arm64) A=aarch64 ;; *) A=x86_64 ;; esac
if [ -s "$OUT/awscliv2.zip" ]; then
  ok "ya está ($(du -h "$OUT/awscliv2.zip" | cut -f1)): no lo descargo"
elif [ -s "$CACHE_DIR/awscliv2.zip" ]; then
  cp -f "$CACHE_DIR/awscliv2.zip" "$OUT/awscliv2.zip"
  ok "reutilizada de la caché ($(du -h "$OUT/awscliv2.zip" | cut -f1)): no la descargo"
elif ! tiene_red; then
  warn "Sin internet y sin offline/awscliv2.zip: los alumnos no podrán instalarla"
else
  if curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$A.zip" -o "$OUT/awscliv2.zip"; then
    guardar_cache "$OUT/awscliv2.zip"
    ok "AWS CLI: $(du -h "$OUT/awscliv2.zip" | cut -f1) (guardada en la caché)"
  else
    warn "No pude descargar la AWS CLI"
  fi
fi

# ── 3. Imágenes de Docker ─────────────────────────────────────────
msg "Guardando las imágenes de Docker (tarda un par de minutos)"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  FALTAN=""
  for IMG in floci/floci:latest postgres:16.3-alpine alpine:3.21 public.ecr.aws/amazonlinux/amazonlinux:2023; do
    docker image inspect "$IMG" >/dev/null 2>&1 || FALTAN="$FALTAN $IMG"
  done
  if [ -n "$FALTAN" ] && [ -s "$CACHE/imagenes-floci.tar.gz" ]; then
    msg "Faltan imágenes: las cargo de la caché (sin internet)"
    if docker load < "$CACHE/imagenes-floci.tar.gz" >/dev/null 2>&1; then
      FALTAN=""
      ok "imágenes cargadas de la caché"
    fi
  fi

  if [ -n "$FALTAN" ]; then
    if tiene_red; then
      warn "Faltan imágenes:$FALTAN — las descargo"
      for IMG in $FALTAN; do docker pull "$IMG" >/dev/null 2>&1; done
    else
      warn "Faltan imágenes:$FALTAN y no hay internet: no las puedo traer"
      warn "Cárgalas antes en este equipo (docker pull una vez) y vuelve a ejecutar."
    fi
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
rm -rf "$TMP/TUIAWSSIM/offline" "$TMP/TUIAWSSIM/offline.tar.gz" "$TMP/TUIAWSSIM/TUIAWSSIM.tar.gz" "$TMP/TUIAWSSIM/index.html" "$TMP/TUIAWSSIM/herramientas.tar.gz" "$TMP/TUIAWSSIM/imagenes-floci.tar.gz" "$TMP/TUIAWSSIM/.git" 2>/dev/null
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

# ── 6. Piezas separadas: el alumno baja solo lo que le falta ──────
msg "Empaquetando por partes"
# herramientas: .deb + instalador de la AWS CLI
tar -czf "$DIR/herramientas.tar.gz" -C "$DIR" offline/paquetes offline/awscliv2.zip 2>/dev/null \
  && ok "herramientas.tar.gz: $(du -h "$DIR/herramientas.tar.gz" | cut -f1)"
# imágenes: ya están en offline/imagenes-floci.tar.gz; copia en la raíz para servirla
[ -f "$DIR/offline/imagenes-floci.tar.gz" ] && cp -f "$DIR/offline/imagenes-floci.tar.gz" "$DIR/imagenes-floci.tar.gz" \
  && ok "imagenes-floci.tar.gz: $(du -h "$DIR/imagenes-floci.tar.gz" | cut -f1)"
# todo junto (por compatibilidad)
tar -czf "$DIR/offline.tar.gz" -C "$DIR" offline
ok "offline.tar.gz: $(du -h "$DIR/offline.tar.gz" | cut -f1)"

# Copia en la caché: la próxima vez no se baja nada aunque se borre el proyecto
msg "Guardando copia en la caché ($CACHE_DIR)"
for f in herramientas.tar.gz imagenes-floci.tar.gz offline.tar.gz; do
  [ -f "$DIR/$f" ] && guardar_cache "$DIR/$f"
done
[ -f "$DIR/offline/imagenes-floci.tar.gz" ] && guardar_cache "$DIR/offline/imagenes-floci.tar.gz"
cp -f "$DIR"/offline/paquetes/*.deb "$CACHE_DIR/paquetes/" 2>/dev/null
ok "caché: $(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)"

echo
msg "Paquete listo: $OUT"
du -sh "$OUT" | sed 's/^/  total: /'
echo
echo "  Ahora reparte con:   ./servir.sh"
