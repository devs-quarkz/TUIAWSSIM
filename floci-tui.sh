#!/usr/bin/env bash
#
# floci-practica.sh — Instalador y guía interactiva de la práctica de Floci
#
#   ./floci-tui.sh            → TUI con menú y guía paso a paso
#   ./floci-tui.sh --auto     → hace toda la práctica sin preguntar
#   ./floci-tui.sh --auto --limpiar → además limpia al terminar
#   ./floci-tui.sh --ayuda    → muestra esta ayuda
#
# Probado en Linux Mint 22.3 y Ubuntu 24.04.
# Uso previsto: una práctica de clase. No hace nada fuera de Docker,
# ~/awsclase, ~/.aws y el fichero de log.
#
set -o pipefail

# En macOS, Docker Desktop trae sus binarios dentro de la app.
if [ -d /Applications/Docker.app/Contents/Resources/bin ]; then
  PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
  export PATH
fi

# ─────────────────────────────────────────────────────────────
#  Constantes
# ─────────────────────────────────────────────────────────────
VERSION_SCRIPT="1.0"
LOG="$HOME/floci-practica.log"
DIR_SCRIPT="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

IMG_BASE="public.ecr.aws/amazonlinux/amazonlinux:2023"
IMG_FLOCI="floci/floci:latest"
IMG_PG="postgres:16.3-alpine"
IMG_ALPINE="alpine:3.21"

NOMBRE_FLOCI="floci"
NOMBRE_EC2="clase"
NOMBRE_DB="clase-db"
DIR_CLASE="$HOME/awsclase"
CLAVE="$DIR_CLASE/clase.pem"

ENDPOINT="http://localhost:4566"
REGION="us-east-1"
DB_USUARIO="admin"
DB_PASS="secreto123"

# Estado de la sesión
PUERTO_DB=7001
IP_INSTANCIA=""
SSH_PUERTO=""
SIN_INTERNET=0
AUTO=0
LIMPIAR=0
SOLO_COMPROBAR=0
EXPORTAR=""
CARGAR=""

# ─────────────────────────────────────────────────────────────
#  Colores y utilidades
# ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_CYAN=$'\033[1;36m'
  C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'
  C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null; }

titulo() {
  printf '\n%s\n%s  %s\n%s\n\n' \
    "${C_CYAN}══════════════════════════════════════════════════════════${C_RESET}" \
    "${C_CYAN} ▶${C_RESET}" "$*" \
    "${C_CYAN}══════════════════════════════════════════════════════════${C_RESET}"
  log "== $* =="
}

ok()    { printf '%s\n' "  ${C_GREEN}✓${C_RESET} $*"; log "OK: $*"; }
aviso() { printf '%s\n' "  ${C_YELLOW}!${C_RESET} $*"; log "AVISO: $*"; }
fallo() { printf '%s\n' "  ${C_RED}✗${C_RESET} $*"; log "FALLO: $*"; }
info()  { printf '%s\n' "  ${C_DIM}$*${C_RESET}"; }

pausa() {
  if [ "$AUTO" = 1 ]; then return 0; fi
  printf '\n  %sPulsa ENTER para continuar...%s' "$C_DIM" "$C_RESET"
  read -r _ || true
}

confirmar() { # confirmar "pregunta" → 0 si sí
  if [ "$AUTO" = 1 ]; then return 0; fi
  printf '\n  %s¿%s? [s/N] ' "$C_BOLD" "$1$C_RESET"
  local r; read -r r || true
  case "$r" in s|S|si|sí|SI|SÍ) return 0 ;; *) return 1 ;; esac
}

# Ejecuta un comando mostrando exactamente lo que se lanza y su salida real
ejecutar() { # ejecutar "descripción" comando...
  local desc="$1"; shift
  printf '  %s$%s %s\n' "$C_DIM" "$C_RESET" "$*"
  log "\$ $*"
  "$@" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then ok "$desc"; else fallo "$desc (código $rc)"; fi
  return "$rc"
}

# ─────────────────────────────────────────────────────────────
#  Comprobaciones del sistema
# ─────────────────────────────────────────────────────────────
hay_comando() { command -v "$1" >/dev/null 2>&1; }

# No basta con que el binario exista: tiene que responder
aws_ok()   { hay_comando aws   && aws --version   >/dev/null 2>&1; }
psql_ok()  { hay_comando psql  && psql --version  >/dev/null 2>&1; }
docker_ok(){ hay_comando docker && docker info    >/dev/null 2>&1; }

tiene_internet() {
  curl -sSf -m 8 -o /dev/null https://awscli.amazonaws.com 2>/dev/null && return 0
  curl -sSf -m 8 -o /dev/null https://registry-1.docker.io 2>/dev/null && return 0
  return 1
}

puerto_libre() {
  if [ "$OS_FAMILIA" = "macos" ]; then
    ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
  fi
}

ssh_puerto_publicado() {
  local c
  c=$(DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -m1 '^floci-aws-ec2' || true)
  [ -n "$c" ] || return 1
  DOCKER port "$c" 22 2>/dev/null | head -1 | sed 's/.*://' | tr -d ' '
}

elegir_puerto_db() {
  # Busca un puerto libre en el rango de Floci (7001-7099).
  local p
  for p in $(seq 7001 7099); do
    if puerto_libre "$p"; then PUERTO_DB="$p"; return 0; fi
  done
  fallo "No hay ningún puerto libre entre 7001 y 7099"
  return 1
}

detectar_docker_cmd() {
  DOCKER_MODO=""
  if ! hay_comando docker; then return 1; fi
  if docker info >/dev/null 2>&1; then
    DOCKER_MODO=""
    return 0
  fi
  if SUDO docker info >/dev/null 2>&1; then
    DOCKER_MODO="sudo"
    aviso "El grupo docker no está activo en esta sesión: usaré 'sudo docker'"
    return 0
  fi
  return 1
}

distro() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${PRETTY_NAME:-desconocida}"
  else
    printf 'desconocida'
  fi
}

# Familia de sistema operativo: debian (Mint/Ubuntu) o macos
OS_FAMILIA=""
OS_ETIQUETA=""
detectar_os() {
  OS_ETIQUETA="$(distro)"
  case "$(uname -s)" in
    Darwin) OS_ETIQUETA="macOS $(sw_vers -productVersion 2>/dev/null)"; OS_FAMILIA="macos"; return 0 ;;
  esac
  case "$(distro)" in
    *Mint*|*Ubuntu*|*Debian*) OS_FAMILIA="debian" ;;
    *) OS_FAMILIA="otro" ;;
  esac
}

architecture() {
  case "$(uname -m)" in
    aarch64|arm64) printf 'aarch64' ;;
    *)             printf 'x86_64' ;;
  esac
}

# Ejecuta sudo; si SUDO_PASS está definida, se la pasa por stdin (útil para
# instalaciones desatendidas o cuando no hay terminal interactiva).
SUDO() {
  if [ -n "${SUDO_PASS:-}" ]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S "$@" 2>/dev/null
  else
    sudo "$@"
  fi
}

# Docker, con sudo si el grupo no está activo en esta sesión.
DOCKER_MODO=""
DOCKER() {
  if [ "$DOCKER_MODO" = "sudo" ]; then SUDO docker "$@"; else docker "$@"; fi
}

pedir_sudo() {
  if sudo -n true 2>/dev/null; then return 0; fi

  # 1) contraseña por variable de entorno (instalaciones desatendidas)
  if [ -n "${SUDO_PASS:-}" ]; then
    if printf '%s\n' "$SUDO_PASS" | sudo -S -v 2>/dev/null; then
      ok "sudo listo (contraseña de SUDO_PASS)"
      return 0
    fi
    fallo "La contraseña de SUDO_PASS no funciona"
    SUDO_PASS=""
  fi

  # 2) preguntarla en el propio TUI
  local intento pass
  for intento in 1 2 3; do
    if [ "$TIENE_WHIPTAIL" = 1 ] && [ -t 2 ]; then
      pass=$(whiptail --title "TUIAWSSIM — contraseña" \
        --passwordbox "Para instalar paquetes necesito tu contraseña de administrador.\n\nNo se guarda en ningún sitio." \
        11 64 3>&1 1>&2 2>&3) || { info "Cancelado"; return 1; }
    elif [ -t 0 ]; then
      printf '\n  Contraseña de sudo (no se verá): '
      read -rs pass; printf '\n'
    else
      fallo "No hay terminal para pedir la contraseña"
      info "Usa: SUDO_PASS='tu_contraseña' ./floci-tui.sh"
      return 1
    fi

    if printf '%s\n' "$pass" | sudo -S -v 2>/dev/null; then
      SUDO_PASS="$pass"
      ok "sudo listo"
      return 0
    fi
    fallo "Contraseña incorrecta (intento $intento de 3)"
  done
  return 1
}

# macOS: Rosetta 2 (el sshd de la instancia es x86_64)
asegurar_rosetta() {
  [ "$OS_FAMILIA" = "macos" ] || return 0
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    ok "Rosetta 2 ya está instalado"
    return 0
  fi
  info "Instalando Rosetta 2 (lo necesita el sshd x86_64 de la instancia)…"
  softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 || true
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    ok "Rosetta 2 instalado"
  else
    aviso "No pude instalar Rosetta 2; el SSH de la instancia podría fallar"
  fi
}

# macOS: Docker Desktop desde el DMG (el cask falla sin terminal)
instalar_docker_desktop_macos() {
  hay_comando brew || { fallo "Necesitas Homebrew: https://brew.sh"; return 1; }
  info "Descargando Docker Desktop (~600 MB)…"
  brew fetch --cask docker >/dev/null 2>&1 || true
  local dmg
  dmg=$(readlink -f "$(ls "$HOME"/Library/Caches/Homebrew/Cask/docker-desktop*.dmg 2>/dev/null | head -1)")
  [ -n "$dmg" ] || { fallo "No se descargó el DMG de Docker Desktop"; return 1; }

  local mnt="/tmp/tuiawssim-dmg-$$"
  mkdir -p "$mnt"
  hdiutil attach "$dmg" -nobrowse -quiet -mountpoint "$mnt" || return 1
  rm -rf /Applications/Docker.app 2>/dev/null
  if ! cp -R "$mnt/Docker.app" /Applications/; then
    hdiutil detach "$mnt" -quiet 2>/dev/null
    fallo "No pude copiar Docker.app a /Applications"
    return 1
  fi
  hdiutil detach "$mnt" -quiet 2>/dev/null; rmdir "$mnt" 2>/dev/null
  # Sin esto macOS la ejecuta "translocada" desde una ruta temporal
  xattr -dr com.apple.quarantine /Applications/Docker.app 2>/dev/null || true
  ok "Docker.app copiada a /Applications"

  pedir_sudo || return 1
  local b=/Applications/Docker.app/Contents/Resources/bin
  SUDO ln -sf "$b/docker" /usr/local/bin/docker
  SUDO ln -sf "$b/docker-credential-desktop" /usr/local/bin/docker-credential-desktop
  SUDO ln -sf "$b/docker-compose" /usr/local/bin/docker-compose
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
  hash -r

  info "Abriendo Docker Desktop (acepta la licencia si te la pide)…"
  open -a Docker 2>/dev/null || true
  info "Esperando al daemon (la primera vez puede tardar varios minutos)…"
  local j
  for j in $(seq 1 200); do
    if docker info >/dev/null 2>&1; then
      ok "Docker responde tras ~$((j*3))s"
      return 0
    fi
    if [ $((j % 20)) -eq 0 ]; then
      info "  …sigo esperando ($((j*3))s). Si macOS te pide algo, acéptalo."
    fi
    sleep 3
  done
  fallo "Docker Desktop no arrancó"
  info "Ábrelo con: open -a Docker"
  return 1
}

# ─────────────────────────────────────────────────────────────
#  BLOQUE 0 y 1 — Instalación
# ─────────────────────────────────────────────────────────────
# Instalar Docker en macOS: Colima (ligero) o Docker Desktop (gráfico)
instalar_docker_macos() {
  if ! hay_comando brew; then
    fallo "Necesitas Homebrew: https://brew.sh"
    return 1
  fi

  asegurar_rosetta

  local eleccion=""
  if [ -n "${DOCKER_MAC:-}" ]; then
    eleccion="$DOCKER_MAC"
    info "Usando DOCKER_MAC=$eleccion"
  elif [ "$AUTO" = 1 ] || [ ! -t 0 ]; then
    eleccion="desktop"
    info "Modo automático: instalo Docker Desktop (es el que funciona con el SSH)"
  else
    eleccion=$(tui_menu "Docker en macOS" \
"  En macOS, Docker necesita una máquina virtual. Dos opciones:

  · Colima: ligero (~1 GB), de terminal, sin iconos. Recomendado.
  · Docker Desktop: la app oficial (~2 GB), con interfaz gráfica.

  ¿Cuál prefieres?" \
      desktop "Docker Desktop (app oficial, ~2 GB) — recomendado" \
      colima "Colima (ligero, sin app, ~1 GB) — el SSH no funciona" \
      cancelar "Cancelar") || return 1
  fi

  case "$eleccion" in
    colima)
      ejecutar "Cliente de Docker instalado" brew install docker || return 1
      ejecutar "Colima instalado" brew install colima || return 1
      info "Arrancando la máquina virtual de Colima (2 CPU, 4 GB RAM, 20 GB disco)…"
      info "La primera vez descarga la imagen de la VM y tarda un par de minutos."
      ejecutar "Colima arrancado" colima start --cpu 2 --memory 4 --disk 20 || return 1
      info "Esperando al demonio de Docker…"
      local i
      for i in $(seq 1 60); do
        if docker info >/dev/null 2>&1; then
          ok "Docker responde a través de Colima tras ~$((i*2))s"
          return 0
        fi
        sleep 2
      done
      fallo "Colima arrancó pero el demonio no responde"
      info "Prueba: colima status   y   docker context ls"
      return 1
      ;;
    desktop)
      instalar_docker_desktop_macos || return 1
      ;;
    *) info "Sin Docker no se puede continuar"; return 1 ;;
  esac
}

instalar_docker() {
  titulo "Docker"

  # ¿Ya funciona? (no basta con que el binario exista)
  if docker_ok; then
    ok "Docker ya funciona: $(docker --version 2>/dev/null | head -1)"
  elif hay_comando docker; then
    aviso "Docker está instalado pero el demonio no responde. Intento repararlo."
    if [ "$OS_FAMILIA" = "debian" ]; then
      pedir_sudo && SUDO systemctl start docker 2>/dev/null
      sleep 2
      SUDO systemctl reset-failed docker 2>/dev/null
      SUDO systemctl start docker 2>/dev/null
      sleep 3
    fi
    if docker_ok; then
      ok "Docker reparado: $(docker --version 2>/dev/null | head -1)"
    else
      aviso "Sigue sin responder: lo reinstalo"
      if [ "$OS_FAMILIA" = "debian" ]; then
        pedir_sudo || return 1
        ejecutar "Docker reinstalado" SUDO env DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y docker.io || true
        SUDO systemctl reset-failed docker 2>/dev/null
        SUDO systemctl start docker 2>/dev/null
        sleep 3
      fi
    fi
  else
    if [ "$SIN_INTERNET" = 1 ]; then
      fallo "No hay internet y Docker no está instalado"
      return 1
    fi
    case "$OS_FAMILIA" in
      macos)
        instalar_docker_macos || return 1
        ;;
      debian)
        pedir_sudo || return 1
        ejecutar "Índices de paquetes actualizados" SUDO apt-get update || true
        ejecutar "Docker instalado" SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io || return 1
        ;;
      *) fallo "Distribución no soportada"; return 1 ;;
    esac
  fi

  # Permisos: si el grupo no está activo, el script usará sudo docker
  if [ "$OS_FAMILIA" != "macos" ] && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    pedir_sudo || return 1
    ejecutar "Añadido al grupo docker" SUDO usermod -aG docker "$USER" || true
    aviso "Para usar 'docker' sin sudo hay que cerrar sesión y volver a entrar."
    info "Mientras tanto este script usará 'sudo docker'."
  fi

  if ! detectar_docker_cmd; then
    if [ "$OS_FAMILIA" = "macos" ] && hay_comando colima; then
      info "El demonio no responde; pruebo a arrancar Colima."
      colima start >/dev/null 2>&1 || true
      detectar_docker_cmd || { fallo "No consigo hablar con el demonio de Docker"; return 1; }
    else
      fallo "No consigo hablar con el demonio de Docker"
      return 1
    fi
  fi
  ok "Usaré: docker${DOCKER_MODO:+ con sudo}"
}

instalar_aws_cli() {
  titulo "AWS CLI v2"
  if aws_ok; then
    ok "AWS CLI ya instalada: $(aws --version 2>&1 | head -1)"
    return 0
  fi
  if [ "$SIN_INTERNET" = 1 ]; then
    fallo "No hay internet y la AWS CLI no está instalada"
    return 1
  fi
  local arq; arq="$(architecture)"
  case "$OS_FAMILIA" in
    macos)
      hay_comando brew || { fallo "Necesitas Homebrew: https://brew.sh"; return 1; }
      ejecutar "AWS CLI con brew" brew install awscli || return 1
      ;;
    debian)
      pedir_sudo || return 1
      ejecutar "unzip instalado" SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y unzip || return 1
      cd "$HOME" || return 1
      ejecutar "Descargando la AWS CLI v2 ($arq)" \
        curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-${arq}.zip" -o awscliv2.zip || return 1
      ejecutar "Descomprimiendo" unzip -q -o awscliv2.zip || return 1
      ejecutar "Instalando la AWS CLI" SUDO ./aws/install --update || return 1
      ;;
    *) fallo "Instala la AWS CLI v2 a mano"; return 1 ;;
  esac
  hash -r
  if hay_comando aws; then
    ok "AWS CLI instalada: $(aws --version 2>&1 | head -1)"
  else
    fallo "La instalación terminó pero 'aws' no aparece en el PATH"
    return 1
  fi
}

instalar_psql() {
  titulo "Cliente de PostgreSQL"
  if psql_ok; then
    ok "psql ya está instalado: $(psql --version)"
    return 0
  fi
  if [ "$SIN_INTERNET" = 1 ]; then
    fallo "No hay internet y psql no está instalado"
    return 1
  fi
  case "$OS_FAMILIA" in
    macos)
      hay_comando brew || { fallo "Necesitas Homebrew: https://brew.sh"; return 1; }
      ejecutar "libpq con brew" brew install libpq || return 1
      export PATH="$(brew --prefix libpq)/bin:$PATH"
      ;;
    debian)
      pedir_sudo || return 1
      ejecutar "psql instalado" SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-client || return 1
      ;;
    *) fallo "Instala el cliente de PostgreSQL a mano"; return 1 ;;
  esac
  ok "psql: $(psql --version 2>/dev/null)"
}

# ─────────────────────────────────────────────────────────────
#  BLOQUE 2 — Imágenes
# ─────────────────────────────────────────────────────────────
tiene_imagen() { DOCKER image inspect "$1" >/dev/null 2>&1; }

exportar_imagenes() { # exportar_imagenes <fichero>
  titulo "Exportar las imágenes para clase sin internet"
  detectar_docker_cmd || { fallo "Docker no está listo"; return 1; }
  local destino="${1:-$PWD/imagenes-floci.tar.gz}"
  info "Se guardan las 4 imágenes en un solo fichero (~250-400 MB comprimido)."
  info "Tarda un par de minutos y ocupa bastante: hazlo con espacio libre."
  mkdir -p "$(dirname "$destino")" 2>/dev/null
  printf '  %s$%s docker save … | gzip > %s\n' "$C_DIM" "$C_RESET" "$destino"
  DOCKER save "$IMG_FLOCI" "$IMG_PG" "$IMG_ALPINE" "$IMG_BASE" | gzip >"$destino"
  if [ -s "$destino" ]; then
    ok "Paquete creado: $destino ($(du -h "$destino" | cut -f1))"
    info "Ponlo junto a instalar.sh en el servidor del profesor."
    info "El alumno solo tiene que ejecutar el instalador: lo detecta y lo carga."
    return 0
  fi
  fallo "No se pudo crear el paquete"
  return 1
}

cargar_imagenes() { # cargar_imagenes <fichero>
  local f="$1"
  if [ ! -f "$f" ]; then fallo "No existe el paquete: $f"; return 1; fi
  titulo "Cargar las imágenes del paquete"
  detectar_docker_cmd || { fallo "Docker no está listo"; return 1; }
  info "Cargando $f ($(du -h "$f" | cut -f1))… puede tardar un par de minutos."
  if gunzip -c "$f" | DOCKER load 2>&1 | tee -a "$LOG" | tail -4; then
    ok "Imágenes cargadas"
    return 0
  fi
  fallo "No se pudieron cargar las imágenes"
  return 1
}

preparar_imagenes() {
  titulo "Imágenes de Docker"
  hay_comando docker || { fallo "Docker no está listo"; return 1; }

  # Si falta alguna imagen y hay un paquete al lado, se carga solo.
  local falta=0 img cand paquete=""
  for img in "$IMG_FLOCI" "$IMG_PG" "$IMG_ALPINE" "$IMG_BASE"; do
    tiene_imagen "$img" || falta=1
  done
  if [ "$falta" = 1 ]; then
    for cand in "$DIR_SCRIPT/imagenes-floci.tar.gz" "$HOME/TUIAWSSIM/imagenes-floci.tar.gz" "$HOME/imagenes-floci.tar.gz"; do
      [ -f "$cand" ] && { paquete="$cand"; break; }
    done
    if [ -n "$paquete" ]; then
      info "Encontré un paquete de imágenes: $paquete"
      cargar_imagenes "$paquete"
    fi
  fi

  local img
  for img in "$IMG_FLOCI" "$IMG_PG" "$IMG_ALPINE" "$IMG_BASE"; do
    if tiene_imagen "$img"; then
      ok "Ya está: $img"
      continue
    fi
    if [ "$SIN_INTERNET" = 1 ]; then
      fallo "Falta $img y no hay internet. Descárgala en casa (bloque 2 del guion)."
      return 1
    fi
    ejecutar "Descargando $img" DOCKER pull "$img" || return 1
  done

  if imagen_ec2_lista; then
    ok "La imagen de EC2 ya está construida y verificada"
  else
    construir_imagen_ec2 || return 1
  fi
}

imagen_ec2_lista() {
  DOCKER run --rm "$IMG_BASE" sh -c 'grep -qx "account required pam_permit.so" /etc/pam.d/sshd && test -x /usr/sbin/sshd' >/dev/null 2>&1
}

construir_imagen_ec2() {
  [ "$SIN_INTERNET" = 1 ] && { fallo "Hace falta internet para construir la imagen de EC2"; return 1; }
  info "Construyendo la imagen de EC2 con servidor SSH (tarda ~1 minuto)..."
  local df
  df=$(mktemp)
  cat >"$df" <<EOF
FROM ${IMG_BASE}
RUN dnf install -y openssh-server openssh-clients && dnf clean all
RUN sed -i /account/d /etc/pam.d/sshd
RUN echo account required pam_permit.so >> /etc/pam.d/sshd
EOF
  ejecutar "Imagen de EC2 construida" DOCKER build -t "$IMG_BASE" -f "$df" . || { rm -f "$df"; return 1; }
  rm -f "$df"

  if imagen_ec2_lista; then
    ok "Verificada: una sola línea 'account' y /usr/sbin/sshd presente"
    return 0
  fi
  fallo "La imagen no pasó la verificación. Revisa el log: $LOG"
  DOCKER run --rm "$IMG_BASE" sh -c 'grep account /etc/pam.d/sshd; ls /usr/sbin/sshd' 2>&1 | tee -a "$LOG"
  return 1
}

# ─────────────────────────────────────────────────────────────
#  BLOQUE 3 — Arrancar Floci y configurar AWS
# ─────────────────────────────────────────────────────────────
configurar_aws() {
  titulo "Configuración de AWS"
  ejecutar "Credenciales de prueba" aws configure set aws_access_key_id test || return 1
  ejecutar "Secreto de prueba" aws configure set aws_secret_access_key test || return 1
  ejecutar "Región" aws configure set region "$REGION" || return 1
  ejecutar "Formato de salida" aws configure set output json || return 1
  ejecutar "Endpoint local de Floci" aws configure set endpoint_url "$ENDPOINT" || return 1
  ejecutar "Paginador desactivado" aws configure set cli_pager "" || return 1
  ok "Queda guardado en ~/.aws/config (una sola vez en la vida)"
}

arrancar_floci() {
  titulo "Arrancar Floci"
  hay_comando docker || { fallo "Docker no está listo"; return 1; }

  if DOCKER ps -a --format '{{.Names}}' | grep -qx "$NOMBRE_FLOCI"; then
    info "Había un contenedor '$NOMBRE_FLOCI' de antes: lo reemplazo"
    ejecutar "Contenedor antiguo eliminado" DOCKER rm -f "$NOMBRE_FLOCI" || true
  fi

  elegir_puerto_db || return 1
  if [ "$PUERTO_DB" = 7001 ]; then
    info "Publico el puerto 7001 (libre)"
  else
    aviso "El 7001 estaba ocupado (¿AnyDesk?). Uso el $PUERTO_DB para la base de datos."
    info "Es el mismo apaño que documenta la guía: solo cambia el -p."
  fi

  # En macOS el socket de Docker Desktop está dentro de la app
  local socket="/var/run/docker.sock"
  if [ "$OS_FAMILIA" = "macos" ] && [ -S "$HOME/.docker/run/docker.sock" ]; then
    socket="$HOME/.docker/run/docker.sock"
    info "Socket de Docker Desktop: $socket"
  fi

  ejecutar "Floci arrancado" \
    DOCKER run -d --name "$NOMBRE_FLOCI" \
      -p "127.0.0.1:4566:4566" \
      -p "127.0.0.1:${PUERTO_DB}:7001" \
      -v "$socket":/var/run/docker.sock \
      -e FLOCI_SERVICES_UI_ENABLED=false \
      -e FLOCI_DNS_CONTAINER_FALLBACK_ENABLED=false \
      "$IMG_FLOCI" || return 1

  info "Esperando a que la API responda..."
  local i
  for i in $(seq 1 60); do
    if curl -s -m 2 "$ENDPOINT/_floci/health" >/dev/null 2>&1; then
      ok "Responde tras ${i}s: $(curl -s "$ENDPOINT/_floci/health" | head -c 120)…"
      break
    fi
    sleep 1
    [ "$i" = 60 ] && { fallo "Floci no responde. Mira: DOCKER logs $NOMBRE_FLOCI"; return 1; }
  done

  configurar_aws || return 1

  info "Test de aceptación..."
  local cuenta
  cuenta=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  if [ "$cuenta" = "000000000000" ]; then
    ok "Account 000000000000 — punto de control superado"
  else
    fallo "El test de aceptación no devolvió 000000000000 (salida: '$cuenta')"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────
#  BLOQUE 4 — Instancia EC2
# ─────────────────────────────────────────────────────────────
crear_instancia() {
  titulo "Crear la instancia EC2"
  mkdir -p "$DIR_CLASE" || return 1

  # La llave tiene que existir EN FLOCI y tener su .pem local. Si Floci se
  # recreó (contenedor nuevo), las llaves de antes ya no existen.
  if aws ec2 describe-key-pairs --key-names "$NOMBRE_EC2" >/dev/null 2>&1 && [ -s "$CLAVE" ]; then
    ok "La llave ya existe en Floci y el .pem está en su sitio"
  else
    info "Creando el par de llaves (no estaba en Floci o faltaba el .pem)…"
    chmod u+w "$CLAVE" 2>/dev/null || true
    rm -f "$CLAVE"
    aws ec2 delete-key-pair --key-name "$NOMBRE_EC2" >/dev/null 2>&1 || true
    aws ec2 create-key-pair --key-name "$NOMBRE_EC2" --query KeyMaterial --output text >"$CLAVE" 2>>"$LOG"
    if [ -s "$CLAVE" ]; then
      chmod 400 "$CLAVE"
      ok "Llave creada ($(wc -c <"$CLAVE" | tr -d ' ') bytes) y con permisos 400"
      local viejas
      viejas=$(aws ec2 describe-instances --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null)
      if [ -n "$viejas" ] && [ "$viejas" != "None" ]; then
        info "Terminando las instancias antiguas (tenían otra llave)…"
        aws ec2 terminate-instances --instance-ids $viejas >/dev/null 2>&1 || true
        sleep 3
      fi
    else
      fallo "No se pudo crear la llave"
      return 1
    fi
  fi

  # ¿Ya hay una instancia corriendo? Aprovecharla.
  IP_INSTANCIA=$(aws ec2 describe-instances --query "Reservations[0].Instances[0].PublicIpAddress" --output text 2>/dev/null)
  local estado
  estado=$(aws ec2 describe-instances --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null)
  if [ "$estado" = "running" ] && [ -n "$IP_INSTANCIA" ] && [ "$IP_INSTANCIA" != "None" ]; then
    ok "Ya había una instancia corriendo en $IP_INSTANCIA"
    return 0
  fi

  info "Lanzando la instancia..."
  aws ec2 run-instances --image-id ami-0abcdef1234567891 --instance-type t2.micro \
      --key-name "$NOMBRE_EC2" >/dev/null 2>>"$LOG"
  [ $? -eq 0 ] || { fallo "run-instances falló"; return 1; }

  local i
  for i in $(seq 1 60); do
    estado=$(aws ec2 describe-instances --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null)
    IP_INSTANCIA=$(aws ec2 describe-instances --query "Reservations[0].Instances[0].PublicIpAddress" --output text 2>/dev/null)
    if [ "$estado" = "running" ] && [ -n "$IP_INSTANCIA" ] && [ "$IP_INSTANCIA" != "None" ]; then
      ok "Instancia running en $IP_INSTANCIA"
      break
    fi
    sleep 2
    [ "$i" = 60 ] && { fallo "La instancia no llegó a 'running'"; return 1; }
  done

  aws ec2 describe-instances \
    --query 'Reservations[].Instances[].{ID:InstanceId,Estado:State.Name,IP:PublicIpAddress}' \
    --output table 2>&1 | tee -a "$LOG"
  return 0
}

# ─────────────────────────────────────────────────────────────
#  BLOQUE 5 — SSH (con la espera larga que descubrimos)
# ─────────────────────────────────────────────────────────────
# Floci puede usar una imagen cacheada sin el arreglo de PAM. Si pasa,
# se remedia dentro de la instancia: borrar las líneas account y poner
# pam_permit, y reiniciar el sshd.
arreglar_pam_instancia() {
  local c
  c=$($DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -m1 '^floci-aws-ec2' || true)
  [ -n "$c" ] || return 0
  if ! $DOCKER exec "$c" test -f /etc/pam.d/sshd >/dev/null 2>&1; then
    return 0   # todavía no está instalado sshd; se reintentará
  fi
  if $DOCKER exec "$c" grep -q pam_permit /etc/pam.d/sshd >/dev/null 2>&1; then
    return 0   # ya está bien
  fi
  info "La imagen en uso no traía el arreglo de PAM; lo aplico dentro de la instancia."
  $DOCKER exec "$c" sh -c "sed -i /account/d /etc/pam.d/sshd; echo account required pam_permit.so >> /etc/pam.d/sshd" >/dev/null 2>&1
  $DOCKER exec "$c" sh -c "pkill sshd 2>/dev/null; sleep 1; /usr/sbin/sshd" >/dev/null 2>&1 || true
  if $DOCKER exec "$c" grep -q pam_permit /etc/pam.d/sshd 2>/dev/null; then
    ok "PAM corregido dentro de la instancia"
  fi
}

esperar_ssh() {
  titulo "Entrar por SSH en la instancia"
  [ -n "$IP_INSTANCIA" ] && [ "$IP_INSTANCIA" != "None" ] || { fallo "No tengo la IP de la instancia"; return 1; }

  info "El sshd de dentro tarda entre 20 s y casi 1 minuto en arrancar."
  info "Voy a probar hasta 3 minutos, sin que tengas que hacer nada."
  local i r puerto
  for i in $(seq 1 60); do
    arreglar_pam_instancia
    puerto=$(ssh_puerto_publicado || true)

    # 1) por la IP de la instancia (lo normal en Linux)
    if [ "$OS_FAMILIA" != "macos" ] && [ -n "$IP_INSTANCIA" ] && \
       [ "$IP_INSTANCIA" != "None" ] && [ "$IP_INSTANCIA" != "127.0.0.1" ]; then
      r=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=4 -o BatchMode=yes \
               -i "$CLAVE" "root@${IP_INSTANCIA}" 'echo LISTO' 2>&1 | tail -1)
      if [ "$r" = "LISTO" ]; then
        ok "El SSH responde tras ~$((i*3))s (por IP ${IP_INSTANCIA})"
        SSH_PUERTO=""
        return 0
      fi
    fi

    # 2) por el puerto publicado (macOS, o si la IP no tiene ruta)
    if [ -n "$puerto" ]; then
      r=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=4 -o BatchMode=yes -p "$puerto" \
               -i "$CLAVE" root@localhost 'echo LISTO' 2>&1 | tail -1)
      if [ "$r" = "LISTO" ]; then
        ok "El SSH responde tras ~$((i*3))s (por el puerto ${puerto})"
        SSH_PUERTO="$puerto"
        return 0
      fi
    fi
    sleep 3
  done
  fallo "El SSH no ha respondido en 3 minutos"
  info "Última salida: $r"
  info "Si dice REMOTE HOST IDENTIFICATION CHANGED: ssh-keygen -f ~/.ssh/known_hosts -R $IP_INSTANCIA"
  return 1
}

entrar_en_instancia() {
  esperar_ssh || return 1
  printf '\n  %sVas a entrar en la instancia. Escribe "exit" para volver.%s\n' "$C_DIM" "$C_RESET"
  if [ -n "$SSH_PUERTO" ]; then
    printf '  %s$%s ssh -p %s -i %s root@localhost\n\n' "$C_DIM" "$C_RESET" "$SSH_PUERTO" "$CLAVE"
    log "\$ ssh -p $SSH_PUERTO -i $CLAVE root@localhost"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PUERTO" -i "$CLAVE" root@localhost
  else
    printf '  %s$%s ssh -i %s root@%s\n\n' "$C_DIM" "$C_RESET" "$CLAVE" "$IP_INSTANCIA"
    log "\$ ssh -i $CLAVE root@$IP_INSTANCIA"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CLAVE" "root@${IP_INSTANCIA}"
  fi
  printf '\n'
  ok "Has vuelto a tu máquina"
}

comprobar_instancia_no_interactivo() {
  esperar_ssh || return 1
  local os
  if [ -n "$SSH_PUERTO" ]; then
    os=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PUERTO" \
          -i "$CLAVE" root@localhost 'grep PRETTY_NAME /etc/os-release; whoami' 2>/dev/null | tr '\n' ' ')
  else
    os=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CLAVE" "root@${IP_INSTANCIA}" \
          'grep PRETTY_NAME /etc/os-release; whoami' 2>/dev/null | tr '\n' ' ')
  fi
  if printf '%s' "$os" | grep -qi "Amazon Linux"; then
    ok "Dentro de la instancia: $os"
    return 0
  fi
  fallo "La instancia no parece ser Amazon Linux: $os"
  return 1
}

# ─────────────────────────────────────────────────────────────
#  BLOQUE 6 — Base de datos y SQL
# ─────────────────────────────────────────────────────────────
crear_base_datos() {
  titulo "Crear la base de datos"
  local estado
  estado=$(aws rds describe-db-instances --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null)

  if [ "$estado" = "available" ]; then
    ok "Ya existía y está disponible"
  else
    info "Creando (${NOMBRE_DB})..."
    aws rds create-db-instance --db-instance-identifier "$NOMBRE_DB" --engine postgres \
        --db-instance-class db.t3.micro --master-username "$DB_USUARIO" \
        --master-user-password "$DB_PASS" --allocated-storage 20 >/dev/null 2>>"$LOG"
    [ $? -eq 0 ] || { fallo "create-db-instance falló"; return 1; }

    local i
    for i in $(seq 1 90); do
      estado=$(aws rds describe-db-instances --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null)
      [ "$estado" = "available" ] && { ok "Disponible tras ~$((i*2))s"; break; }
      [ $((i % 10)) -eq 0 ] && info "Estado: ${estado:-creando}…"
      sleep 2
    done
    [ "$estado" = "available" ] || { fallo "No llegó a 'available' (estado: $estado)"; return 1; }
  fi

  aws rds describe-db-instances \
    --query 'DBInstances[].{ID:DBInstanceIdentifier,Estado:DBInstanceStatus,Motor:Engine,Host:Endpoint.Address,Puerto:Endpoint.Port}' \
    --output table 2>&1 | tee -a "$LOG"

  info "El Host interno (172.x) NO se usa: conéctate por localhost y el puerto $PUERTO_DB."
  return 0
}

consulta_version() {
  titulo "Consultar la versión de PostgreSQL"
  info "psql tiene paginador, como la AWS CLI: por eso va -P pager=off."
  local out
  out=$(PGPASSWORD="$DB_PASS" psql -P pager=off -h localhost -p "$PUERTO_DB" -U "$DB_USUARIO" -d postgres \
        -c "SELECT version();" 2>&1) || { fallo "psql no pudo conectar en el puerto $PUERTO_DB"; printf '%s\n' "$out"; return 1; }
  printf '%s\n\n' "$out" | tee -a "$LOG"
  if printf '%s' "$out" | grep -q "PostgreSQL 16"; then
    ok "Conexión correcta: PostgreSQL 16"
    return 0
  fi
  fallo "Conectó pero la versión no es la esperada"
  return 1
}

crear_tabla() {
  titulo "Crear una tabla e insertar datos"
  local f; f=$(mktemp)
  cat >"$f" <<'SQL'
\pset pager off
CREATE TABLE alumnos (id SERIAL PRIMARY KEY, nombre VARCHAR(50), nota NUMERIC(4,2));
INSERT INTO alumnos (nombre, nota) VALUES ('Ana', 8.5), ('Luis', 6.0), ('Marta', 9.25);
SELECT * FROM alumnos;
SQL
  local out
  out=$(PGPASSWORD="$DB_PASS" psql -P pager=off -h localhost -p "$PUERTO_DB" \
        -U "$DB_USUARIO" -d postgres -f "$f" 2>&1)
  rm -f "$f"
  printf '%s\n\n' "$out" | tee -a "$LOG"
  if printf '%s' "$out" | grep -q "Marta"; then
    ok "Tabla creada y tres filas insertadas"
    return 0
  fi
  fallo "No se pudo crear la tabla"
  return 1
}

consola_psql() {
  titulo "Consola de psql"
  printf '  %sVas a entrar en psql. Prueba: SELECT * FROM alumnos;  y sal con \\q%s\n' "$C_DIM" "$C_RESET"
  printf '  %s$%s PGPASSWORD=… psql -h localhost -p %s -U %s -d postgres\n\n' \
    "$C_DIM" "$C_RESET" "$PUERTO_DB" "$DB_USUARIO"
  PGPASSWORD="$DB_PASS" psql -P pager=off -h localhost -p "$PUERTO_DB" -U "$DB_USUARIO" -d postgres
  printf '\n'
  ok "Has salido de psql"
}

# ─────────────────────────────────────────────────────────────
#  BLOQUE 7 — Limpieza
# ─────────────────────────────────────────────────────────────
limpiar_todo() {
  titulo "Limpiar"
  if [ -n DOCKER ]; then
    local ids
    ids=$(aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
    if [ -n "$ids" ] && [ "$ids" != "None" ]; then
      info "Terminando instancias: $ids"
      aws ec2 terminate-instances --instance-ids $ids >/dev/null 2>>"$LOG" && ok "Instancias terminadas"
    fi
    aws rds delete-db-instance --db-instance-identifier "$NOMBRE_DB" --skip-final-snapshot \
        >/dev/null 2>>"$LOG" && ok "Base de datos borrada"

    DOCKER rm -f "$NOMBRE_FLOCI" >/dev/null 2>&1 && ok "Contenedor floci eliminado"
    # Contenedores auxiliares de Floci (volúmenes de instancias)
    local aux
    for aux in $(DOCKER ps -a --format '{{.Names}}' | grep '^floci-aws-ec2' || true); do
      DOCKER rm -f "$aux" >/dev/null 2>&1 && info "Auxiliar eliminado: $aux"
    done
  fi
  rm -rf "$DIR_CLASE" && ok "Carpeta ~/awsclase borrada"
  printf '\n  %sLas imágenes se conservan para la próxima vez.%s\n' "$C_DIM" "$C_RESET"
}

# ─────────────────────────────────────────────────────────────
#  Diagnóstico
# ─────────────────────────────────────────────────────────────
comprobar_equipo() {
  titulo "Comprobando el equipo"
  printf '  Sistema:   %s\n' "${OS_ETIQUETA:-$(distro)}"
  printf '  Arquitectura: %s\n' "$(uname -m)"
  printf '  Kernel:    %s\n' "$(uname -r)"
  printf '  Disco libre: %s\n' "$(df -h "$HOME" | awk 'NR==2{print $4}')"
  echo

  case "$OS_FAMILIA" in
    debian) ok "Linux compatible (Mint/Ubuntu/Debian)" ;;
    macos)  ok "macOS compatible (necesita Docker Desktop y Homebrew)" ;;
    *)      aviso "Sistema no probado: solo Mint, Ubuntu y macOS" ;;
  esac

  if tiene_internet; then
    ok "Hay internet (se puede descargar todo)"
  else
    SIN_INTERNET=1
    aviso "No hay internet: solo se puede continuar si todo está ya descargado"
  fi

  if docker_ok; then
    ok "Docker: $(docker --version 2>/dev/null | head -1) — el demonio responde"
    if docker info 2>/dev/null | grep -qi podman; then
      aviso "Ojo: ese 'docker' es en realidad PODMAN."
      aviso "Floci no funciona con Podman: las instancias se crean sin contenedor y el SSH no funciona."
      info "Instala el Docker de verdad (docker.io o Docker Desktop)."
    fi
  elif hay_comando docker; then
    aviso "Docker está instalado pero el demonio NO responde (lo intentaré reparar)"
  else
    aviso "Docker no está instalado (lo hará el paso de instalación)"
  fi

  if aws_ok; then ok "AWS CLI: $(aws --version 2>&1 | head -1)"; else aviso "AWS CLI no instalada (o rota)"; fi
  if psql_ok; then ok "psql: $(psql --version)"; else aviso "psql no instalado (o roto)"; fi
  if [ "$TIENE_WHIPTAIL" = 1 ]; then ok "Interfaz whiptail disponible"; else aviso "Sin whiptail: usaré modo texto"; fi

  # Conflictos de puertos (AnyDesk y compañía)
  local conflictos="" p
  for p in $(seq 7001 7099); do
    puerto_libre "$p" || conflictos="$conflictos $p"
  done
  if [ -n "$conflictos" ]; then
    aviso "Puertos ocupados en el rango 7001-7099:$conflictos"
    info "Suele ser AnyDesk (7070). El script usará el primer puerto libre."
  else
    ok "Rango 7001-7099 libre"
  fi

  if hay_comando docker; then
    ok "Docker usable: ${DOCKER_MODO:+con sudo}${DOCKER_MODO:-directo}"
  fi
  echo
  detectar_docker_cmd >/dev/null 2>&1 || true
  if [ "$DOCKER_MODO" = "sudo" ]; then
    aviso "El grupo docker no está activo: el script usará 'sudo docker'"
  fi
}

# ─────────────────────────────────────────────────────────────
#  Flujos
# ─────────────────────────────────────────────────────────────
flujo_completo() {
  comprobar_equipo
  confirmar "¿Instalo lo que falte y hago toda la práctica?" || return 0

  instalar_docker        || return 1
  instalar_aws_cli       || return 1
  instalar_psql          || return 1
  preparar_imagenes      || return 1
  arrancar_floci         || return 1
  crear_instancia        || return 1
  crear_base_datos       || return 1
  consulta_version       || return 1
  crear_tabla            || return 1

  if [ "$AUTO" = 0 ]; then
    printf '\n'
    if confirmar "¿Quieres entrar por SSH en la instancia ahora?"; then
      entrar_en_instancia || true
    fi
    if confirmar "¿Quieres abrir la consola de psql?"; then
      consola_psql || true
    fi
  else
    comprobar_instancia_no_interactivo || true
  fi

  titulo "Práctica completada"
  printf '  %sHas creado una instancia EC2 y una base de datos PostgreSQL%s\n' "$C_GREEN" "$C_RESET"
  printf '  %susando Floci, sin cuenta de AWS y sin internet.%s\n\n' "$C_GREEN" "$C_RESET"
  info "Instancia: $IP_INSTANCIA (Amazon Linux 2023, usuario root)"
  info "Base de datos: localhost:$PUERTO_DB (usuario $DB_USUARIO, contraseña $DB_PASS)"
  info "Log completo: $LOG"

  if [ "$LIMPIAR" = 1 ]; then
    limpiar_todo
  else
    info "Cuando termines: ./floci-practica.sh --auto --limpiar   (o la opción 9 del menú)"
  fi
}

# ─────────────────────────────────────────────────────────────
#  TUI
# ─────────────────────────────────────────────────────────────
TIENE_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && TIENE_WHIPTAIL=1

tui_msg() { # tui_msg "texto" [alto] [ancho]
  local texto="$1" alto="${2:-20}" ancho="${3:-78}"
  if [ "$TIENE_WHIPTAIL" = 1 ]; then
    whiptail --title "Floci — práctica de AWS" --msgbox "$texto" "$alto" "$ancho" 3>&1 1>&2 2>&3
  else
    printf '\n%s\n\n' "$texto"
    pausa
  fi
}

tui_menu() { # tui_menu "título" "texto" tag desc tag desc …
  local tit="$1" texto="$2"; shift 2
  if [ "$TIENE_WHIPTAIL" = 1 ]; then
    whiptail --title "Floci — práctica de AWS" --menu "$texto" 24 78 12 "$@" 3>&1 1>&2 2>&3
  else
    printf '\n%s\n%s\n\n' "$tit" "$texto"
    local -a a=("$@") i=0
    while [ $i -lt ${#a[@]} ]; do
      printf '  %-6s %s\n' "${a[$i]}" "${a[$((i+1))]}"
      i=$((i+2))
    done
    printf '\n  Opción: '
    read -r r
    printf '%s' "$r"
  fi
}

tui_pantalla() {
  clear 2>/dev/null || true
  cat <<EOF
${C_CYAN}  ███████╗██╗      ██████╗  ██████╗██╗
  ██╔════╝██║     ██╔═══██╗██╔════╝██║
  █████╗  ██║     ██║   ██║██║     ██║
  ██╔══╝  ██║     ██║   ██║██║     ██║
  ██║     ███████╗╚██████╔╝╚██████╗██║
  ╚═╝     ╚══════╝ ╚═════╝  ╚═════╝╚═╝${C_RESET}
  ${C_DIM}práctica de AWS en tu portátil · ${OS_ETIQUETA:-sin detectar}${C_RESET}
EOF
}

menu_principal() {
  local opcion
  if [ ! -t 0 ]; then
    aviso "No hay una terminal interactiva (¿lo estás lanzando desde un script?)."
    info "Usa el modo automático:  ./floci-tui.sh --auto"
    info "O el diagnóstico:        ./floci-tui.sh --comprobar"
    return 1
  fi
  while true; do
    tui_pantalla
    # El estado resumido debajo del banner
    if [ -n "$IR_INSTANCIA" ] 2>/dev/null; then :; fi
    opcion=$(tui_menu "Menú principal" \
"  Elige qué hacer. Lo más fácil: la opción 1.

  Estado actual:
    Docker:     ${DOCKER_MODO:+docker con sudo}${DOCKER_MODO:-docker}
    Instancia:  ${IP_INSTANCIA:-ninguna}
    Puerto DB:  ${PUERTO_DB}" \
      1 "Empezar la práctica guiada (instala y hace todo)" \
      2 "Comprobar el equipo" \
      3 "Instalar Docker, AWS CLI y psql" \
      4 "Preparar las imágenes" \
      5 "Arrancar Floci y configurar AWS" \
      6 "Crear la instancia EC2" \
      7 "Entrar por SSH en la instancia" \
      8 "Crear la base de datos" \
      9 "Consultar y crear tablas con SQL" \
     10 "Limpieza final" \
     12 "Exportar imágenes para clase sin internet (profesor)" \
     11 "Ver el log" \
      0 "Salir" ) || break

    case "$opcion" in
      1) flujo_completo; pausa ;;
      2) comprobar_equipo; pausa ;;
      3) instalar_docker && instalar_aws_cli && instalar_psql; pausa ;;
      4) preparar_imagenes; pausa ;;
      5) arrancar_floci; pausa ;;
      6) crear_instancia; pausa ;;
      7) entrar_en_instancia; pausa ;;
      8) crear_base_datos; pausa ;;
      9) consulta_version && crear_tabla && consola_psql; pausa ;;
     10) confirmar "¿Seguro que quieres limpiar todo?" && limpiar_todo; pausa ;;
     12) exportar_imagenes; pausa ;;
     11) [ -f "$LOG" ] && { clear; tail -40 "$LOG"; pausa; } ;;
      0) break ;;
      *) ;;
    esac
  done
}

# ─────────────────────────────────────────────────────────────
#  Argumentos
# ─────────────────────────────────────────────────────────────
mostrar_ayuda() {
  cat <<EOF
floci-tui.sh — instalador y guía de la práctica de Floci

  ./floci-tui.sh                    Menú interactivo (TUI)
  ./floci-tui.sh --auto             Hace toda la práctica sin preguntar
  ./floci-tui.sh --auto --limpiar   …y limpia al terminar
  ./floci-tui.sh --comprobar        Solo diagnostica, sin tocar nada
  ./floci-tui.sh --exportar [f]     Guarda las 4 imágenes en un fichero (profesor)
  ./floci-tui.sh --cargar <f>       Carga ese fichero de imágenes (alumno)

En macOS:
  DOCKER_MAC=colima   ./floci-tui.sh    instala Colima (ligero, recomendado)
  DOCKER_MAC=desktop  ./floci-tui.sh    instala Docker Desktop
  ./floci-tui.sh --ayuda            Esto

Hace, en orden:
  0-1  Instala Docker, la AWS CLI v2 y psql si faltan
  2    Descarga las imágenes y construye la de EC2
  3    Arranca Floci y configura ~/.aws/config
  4    Crea la llave y una instancia EC2
  5    Entra por SSH en la instancia (Amazon Linux 2023)
  6    Crea una base de datos PostgreSQL y consulta con SQL
  7    Limpia (opcional)

Todo queda en Docker, ~/awsclase, ~/.aws y ~/floci-practica.log.
Probado en Linux Mint 22.3 y Ubuntu 24.04.
EOF
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto)      AUTO=1 ;;
      --comprobar) SOLO_COMPROBAR=1 ;;
      --exportar)  EXPORTAR="${2:-$PWD/imagenes-floci.tar.gz}"; shift ;;
      --cargar)    CARGAR="$2"; shift ;;
      --limpiar)  LIMPIAR=1 ;;
      --ayuda|-h|--help) mostrar_ayuda; exit 0 ;;
      *) printf 'Opción desconocida: %s (usa --ayuda)\n' "$1"; exit 2 ;;
    esac
    shift
  done

  detectar_os
  : >"$LOG" 2>/dev/null || true
  log "floci-practica.sh $VERSION_SCRIPT — inicio (auto=$AUTO limpiar=$LIMPIAR)"

  if [ -n "$EXPORTAR" ]; then exportar_imagenes "$EXPORTAR"; exit $?; fi
  if [ -n "$CARGAR" ];   then cargar_imagenes "$CARGAR";   exit $?; fi

  if [ "$SOLO_COMPROBAR" = 1 ]; then
    printf '%s\n' "${C_BOLD}TUIAWSSIM — comprobación del equipo${C_RESET}"
    comprobar_equipo
    exit 0
  fi

  if [ "$AUTO" = 1 ]; then
    printf '%s\n' "${C_BOLD}Floci — práctica automática${C_RESET}"
    printf '%s\n' "${C_DIM}Log: $LOG${C_RESET}"
    flujo_completo
    printf '\n%s%s%s\n' "$C_DIM" "Fin. Log: $LOG" "$C_RESET"
    exit 0
  fi

  menu_principal
  printf '\n%sHasta luego.%s\n' "$C_DIM" "$C_RESET"
}

main "$@"
