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

# ─────────────────────────────────────────────────────────────
#  Constantes
# ─────────────────────────────────────────────────────────────
VERSION_SCRIPT="1.0"
LOG="$HOME/floci-practica.log"

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
  if [ -n "${SUDO_PASS:-}" ]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -v 2>/dev/null && { ok "sudo listo (contraseña de SUDO_PASS)"; return 0; }
    fallo "La contraseña de SUDO_PASS no funciona"
    return 1
  fi
  info "Se necesita sudo para instalar paquetes. Te lo pido una vez."
  if ! sudo -v; then
    fallo "Sin sudo no puedo instalar paquetes"
    info "Si no hay terminal interactiva: SUDO_PASS='tu_contraseña' ./floci-tui.sh --auto"
    return 1
  fi
  ok "sudo listo"
}

# ─────────────────────────────────────────────────────────────
#  BLOQUE 0 y 1 — Instalación
# ─────────────────────────────────────────────────────────────
instalar_docker() {
  titulo "Docker"
  if hay_comando docker; then
    ok "Docker ya está instalado: $(docker --version 2>/dev/null | head -1)"
  else
    if [ "$SIN_INTERNET" = 1 ]; then
      fallo "No hay internet y Docker no está instalado"
      return 1
    fi
    case "$OS_FAMILIA" in
      macos)
        fallo "Docker no está instalado en este Mac"
        info "Instala Docker Desktop desde https://www.docker.com/products/docker-desktop/"
        return 1
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

  detectar_docker_cmd || { fallo "No consigo hablar con el demonio de Docker"; return 1; }
  ok "Usaré: docker${DOCKER_MODO:+ con sudo}"
}

instalar_aws_cli() {
  titulo "AWS CLI v2"
  if hay_comando aws; then
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
  if hay_comando psql; then
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

preparar_imagenes() {
  titulo "Imágenes de Docker"
  hay_comando docker || { fallo "Docker no está listo"; return 1; }

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

  ejecutar "Floci arrancado" \
    DOCKER run -d --name "$NOMBRE_FLOCI" \
      -p "127.0.0.1:4566:4566" \
      -p "127.0.0.1:${PUERTO_DB}:7001" \
      -v /var/run/docker.sock:/var/run/docker.sock \
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

  if [ -s "$CLAVE" ]; then
    ok "La llave ya existe: $CLAVE"
    DOCKER exec "$NOMBRE_FLOCI" sh -c "true" >/dev/null 2>&1 || true
  else
    aws ec2 create-key-pair --key-name "$NOMBRE_EC2" --query KeyMaterial --output text >"$CLAVE" 2>>"$LOG"
    if [ -s "$CLAVE" ]; then
      chmod 400 "$CLAVE"
      ok "Llave creada ($(wc -c <"$CLAVE" | tr -d ' ') bytes) y con permisos 400"
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
esperar_ssh() {
  titulo "Entrar por SSH en la instancia"
  [ -n "$IP_INSTANCIA" ] && [ "$IP_INSTANCIA" != "None" ] || { fallo "No tengo la IP de la instancia"; return 1; }

  info "El sshd de dentro tarda entre 20 s y casi 1 minuto en arrancar."
  info "Voy a probar hasta 3 minutos, sin que tengas que hacer nada."
  local i r puerto
  for i in $(seq 1 60); do
    puerto=$(ssh_puerto_publicado || true)
    if [ "$OS_FAMILIA" = "macos" ] && [ -n "$puerto" ]; then
      r=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=4 -o BatchMode=yes -p "$puerto" \
               -i "$CLAVE" root@localhost 'echo LISTO' 2>&1 | tail -1)
    else
      r=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=4 -o BatchMode=yes \
               -i "$CLAVE" "root@${IP_INSTANCIA}" 'echo LISTO' 2>&1 | tail -1)
    fi
    if [ "$r" = "LISTO" ]; then
      ok "El SSH responde tras ~$((i*3))s (puerto ${puerto:-22})"
      SSH_PUERTO="$puerto"
      return 0
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

  if hay_comando docker; then
    ok "Docker: $(docker --version 2>/dev/null | head -1)"
  else
    aviso "Docker no está instalado (lo hará el paso de instalación)"
  fi

  if hay_comando aws; then ok "AWS CLI: $(aws --version 2>&1 | head -1)"; else aviso "AWS CLI no instalada"; fi
  if hay_comando psql; then ok "psql: $(psql --version)"; else aviso "psql no instalado"; fi
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

  [ -n DOCKER ] && ok "Docker usable como: $DOCKER"
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
      --limpiar)  LIMPIAR=1 ;;
      --ayuda|-h|--help) mostrar_ayuda; exit 0 ;;
      *) printf 'Opción desconocida: %s (usa --ayuda)\n' "$1"; exit 2 ;;
    esac
    shift
  done

  detectar_os
  : >"$LOG" 2>/dev/null || true
  log "floci-practica.sh $VERSION_SCRIPT — inicio (auto=$AUTO limpiar=$LIMPIAR)"

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
