#!/usr/bin/env bash
#
# verificar.sh — autoevaluación de la práctica "una nube de AWS en tu portátil".
#
#   ./practica/verificar.sh              evalúa todo y muestra la tabla
#   ./practica/verificar.sh --bloque 4   solo el bloque 4
#   ./practica/verificar.sh --guardar    evalúa y guarda la entrega
#   ./practica/verificar.sh --json       solo el JSON (para máquinas)
#
# Compatible con bash 3.2 (el de macOS): no usa arrays asociativos.
#
set -o pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CLAVE="$HOME/awsclase/clase.pem"
# El alumno puede llamar al fichero como quiera: vale cualquier .pem suyo
if [ ! -s "$CLAVE" ]; then
  for _c in "$HOME"/awsclase/*.pem "$HOME"/*.pem; do
    [ -s "$_c" ] && { CLAVE="$_c"; break; }
  done
fi
IMG_BASE="public.ecr.aws/amazonlinux/amazonlinux:2023"
PUERTO_FLOCI=4566
PUERTO_DB=7001
DB_ID="clase-db"
DB_USER="admin"
DB_PASS="secreto123"

if [ -t 1 ]; then
  V='\033[1;32m'; R='\033[1;31m'; A='\033[1;33m'; C='\033[1;36m'; B='\033[1m'; N='\033[0m'
else
  V=''; R=''; A=''; C=''; B=''; N=''
fi

# ── criterios, en el orden en que se muestran ──────────────────────
CRITERIOS=(entorno floci credenciales llavero instancia imagen_ec2 ssh rds psql tabla)

puntos_de() {
  case "$1" in
    entorno) echo 10 ;; floci) echo 10 ;; credenciales) echo 5 ;;
    llavero) echo 5 ;; instancia) echo 10 ;; imagen_ec2) echo 5 ;;
    ssh) echo 15 ;; rds) echo 10 ;; psql) echo 10 ;; tabla) echo 20 ;;
    *) echo 0 ;;
  esac
}

bloque_de() {
  case "$1" in
    entorno) echo 0 ;; floci) echo 1 ;; credenciales) echo 1 ;;
    llavero) echo 2 ;; instancia) echo 3 ;; imagen_ec2) echo 3 ;;
    ssh) echo 4 ;; rds) echo 5 ;; psql) echo 6 ;; tabla) echo 7 ;;
    *) echo 0 ;;
  esac
}

SOLO_BLOQUE=""
GUARDAR=0
SOLO_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --bloque)   SOLO_BLOQUE="${2:-}"; shift 2 ;;
    --guardar)  GUARDAR=1; shift ;;
    --json)     SOLO_JSON=1; shift ;;
    -h|--ayuda) sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opción no válida: $1" >&2; exit 2 ;;
  esac
done

# ── utilidades ─────────────────────────────────────────────────────
hay() { command -v "$1" >/dev/null 2>&1; }

# El cliente de AWS: si no tiene endpoint configurado, se le pasa a mano.
AWSQ() {
  if [ -z "${AWS_ENDPOINT_OK:-}" ]; then
    if aws sts get-caller-identity >/dev/null 2>&1; then
      AWS_ENDPOINT_OK=1
    else
      AWS_ENDPOINT_OK=0
    fi
  fi
  if [ "$AWS_ENDPOINT_OK" = 1 ]; then aws "$@"
  else aws --endpoint-url "http://localhost:$PUERTO_FLOCI" "$@"; fi
}

# El alumno puede haber publicado la base de datos en otro puerto: se pregunta a
# la API cuál es el endpoint real.
PUERTO_DB_REAL=""
puerto_db() {
  [ -n "$PUERTO_DB_REAL" ] && { printf '%s' "$PUERTO_DB_REAL"; return 0; }
  local p
  p=$(AWSQ rds describe-db-instances \
        --query "DBInstances[?DBInstanceStatus=='available'].Endpoint.Port" \
        --output text 2>/dev/null | awk 'NF{print $1; exit}')
  case "$p" in ''|None) p="$PUERTO_DB" ;; esac
  PUERTO_DB_REAL="$p"
  printf '%s' "$p"
}

psqlq() {
  PGPASSWORD="$DB_PASS" psql -P pager=off -t -A -h localhost -p "$(puerto_db)" \
    -U "$DB_USER" -d postgres -c "$1" 2>/dev/null
}

# ── comprobaciones: dejan el texto en DETALLE y devuelven 0/1 ──────
chk_entorno() {
  hay docker || { DETALLE="docker no está instalado"; return 1; }
  local v
  v=$(docker info --format '{{.ServerVersion}}' 2>/dev/null)
  if [ -z "$v" ]; then DETALLE="docker está, pero el demonio no responde"; return 1; fi
  DETALLE="Docker $v responde"
}

chk_floci() {
  local h
  h=$(curl -s -m 5 "http://localhost:$PUERTO_FLOCI/_floci/health" 2>/dev/null)
  if printf '%s' "$h" | grep -q '"version"'; then
    DETALLE="Floci escuchando en $PUERTO_FLOCI"
    return 0
  fi
  if hay docker && docker ps --filter name=floci --format '{{.Names}}' 2>/dev/null | grep -q floci; then
    DETALLE="el contenedor existe pero no responde (espera unos segundos)"
  else
    DETALLE="no hay Floci corriendo"
  fi
  return 1
}

chk_credenciales() {
  hay aws || { DETALLE="la AWS CLI no está instalada"; return 1; }
  local acc
  acc=$(AWSQ sts get-caller-identity --query Account --output text 2>/dev/null | awk '{print $1}')
  if [ "$acc" = "000000000000" ]; then
    DETALLE="cuenta de emulador 000000000000"
    return 0
  fi
  if [ -z "$acc" ] || [ "$acc" = "None" ]; then
    DETALLE="sin credenciales o sin endpoint configurado"
  else
    DETALLE="la cuenta es $acc (debería ser 000000000000)"
  fi
  return 1
}

chk_imagen_ec2() {
  if ! hay docker || ! docker image inspect "$IMG_BASE" >/dev/null 2>&1; then
    DETALLE="falta la imagen $IMG_BASE"
    return 1
  fi
  if docker run --rm "$IMG_BASE" sh -c \
      'grep -qx "account required pam_permit.so" /etc/pam.d/sshd && test -x /usr/sbin/sshd' \
      >/dev/null 2>&1; then
    DETALLE="la AMI trae sshd y el arreglo de PAM"
    return 0
  fi
  DETALLE="la imagen no trae sshd o le falta el arreglo de PAM"
  return 1
}

chk_llavero() {
  [ -s "$CLAVE" ] || { DETALLE="no existe $CLAVE"; return 1; }
  local tam permisos
  tam=$(wc -c <"$CLAVE" 2>/dev/null | tr -d ' ')
  case "$(uname -s)" in
    Darwin) permisos=$(stat -f '%Lp' "$CLAVE" 2>/dev/null) ;;
    *)      permisos=$(stat -c '%a' "$CLAVE" 2>/dev/null) ;;
  esac
  if [ "${tam:-0}" -lt 500 ]; then
    DETALLE="el .pem parece vacío ($tam bytes)"
    return 1
  fi
  if [ "$permisos" != "400" ] && [ "$permisos" != "600" ]; then
    DETALLE="permisos $permisos (deberían ser 400): chmod 400 ~/awsclase/clase.pem"
    return 1
  fi
  DETALLE="clave de $tam bytes con permisos $permisos"
}

# Deja IP_INSTANCIA / ESTADO_INSTANCIA con lo que diga la API.
info_instancia() {
  IP_INSTANCIA=""
  ESTADO_INSTANCIA=""
  local fila
  fila=$(AWSQ ec2 describe-instances \
    --query "Reservations[].Instances[?State.Name=='running'].[InstanceId,State.Name,PublicIpAddress]" \
    --output text 2>/dev/null | awk 'NF{print; exit}')
  if [ -n "$fila" ]; then
    ESTADO_INSTANCIA=$(printf '%s' "$fila" | awk '{print $2}')
    IP_INSTANCIA=$(printf '%s' "$fila" | awk '{print $3}')
  fi
}

chk_instancia() {
  info_instancia
  if [ "$ESTADO_INSTANCIA" = "running" ]; then
    DETALLE="instancia en marcha (IP ${IP_INSTANCIA:-sin IP})"
    return 0
  fi
  DETALLE="no hay ninguna instancia en estado running"
  return 1
}

# Puerto publicado del contenedor de la instancia (macOS, o IP sin ruta).
puerto_ssh_publicado() {
  hay docker || return 1
  local cid
  cid=$(docker ps --format '{{.Names}} {{.ID}}' 2>/dev/null | awk '/^floci-aws-ec2/{print $2; exit}')
  [ -n "$cid" ] || return 1
  docker port "$cid" 22/tcp 2>/dev/null | head -1 | sed 's/.*:\([0-9]\{1,\}\)$/\1/'
}

prueba_ssh() {   # $1 = puerto (vacío = por IP)
  local key="$CLAVE" salida
  [ -s "$key" ] || return 1
  if [ -n "$1" ]; then
    salida=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                  -o ConnectTimeout=6 -o BatchMode=yes -p "$1" \
                  -i "$key" root@localhost 'grep PRETTY_NAME /etc/os-release' 2>/dev/null)
  else
    [ -n "$IP_INSTANCIA" ] && [ "$IP_INSTANCIA" != "None" ] || return 1
    salida=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                  -o ConnectTimeout=6 -o BatchMode=yes \
                  -i "$key" "root@$IP_INSTANCIA" 'grep PRETTY_NAME /etc/os-release' 2>/dev/null)
  fi
  printf '%s' "$salida" | grep -qi 'Amazon Linux'
}

chk_ssh() {
  info_instancia
  if prueba_ssh ""; then
    DETALLE="entras en Amazon Linux por IP ($IP_INSTANCIA)"
    return 0
  fi
  local puerto
  puerto=$(puerto_ssh_publicado)
  if [ -n "$puerto" ] && prueba_ssh "$puerto"; then
    DETALLE="entras en Amazon Linux por el puerto $puerto"
    return 0
  fi
  if [ ! -s "$CLAVE" ]; then
    DETALLE="no hay llave para probar"
  elif [ -z "$ESTADO_INSTANCIA" ]; then
    DETALLE="no hay instancia en marcha"
  else
    DETALLE="no consigo entrar (¿esperaste a sshd? ¿creaste la llave antes de la instancia?)"
  fi
  return 1
}

chk_rds() {
  hay aws || { DETALLE="la AWS CLI no está instalada"; return 1; }
  local lista id estado
  lista=$(AWSQ rds describe-db-instances \
            --query "DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]" --output text 2>/dev/null)
  id=$(printf '%s\n' "$lista" | awk -v d="$DB_ID" '$1==d{print $1; exit}')
  [ -z "$id" ] && id=$(printf '%s\n' "$lista" | awk 'NF{print $1; exit}')
  if [ -z "$id" ]; then
    DETALLE="no hay ninguna base de datos creada"
    return 1
  fi
  estado=$(printf '%s\n' "$lista" | awk -v i="$id" '$1==i{print $2; exit}')
  case "$estado" in
    available) DETALLE="base de datos '$id' disponible"; return 0 ;;
    creating)  DETALLE="'$id' todavía creándose: espera y repite"; return 1 ;;
    *)         DETALLE="'$id' en estado ${estado:-?}"; return 1 ;;
  esac
}

chk_psql() {
  hay psql || { DETALLE="psql no está instalado"; return 1; }
  local v
  v=$(psqlq 'SELECT version();' | head -1)
  if printf '%s' "$v" | grep -qi postgres; then
    DETALLE=$(printf '%s' "$v" | sed 's/ on .*//' | cut -c1-42)
    return 0
  fi
  DETALLE="no conecta (¿está la base de datos en available?)"
  return 1
}

chk_tabla() {
  hay psql || { DETALLE="psql no está instalado"; return 1; }
  local n
  n=$(psqlq 'SELECT COUNT(*) FROM alumnos;' | head -1 | tr -d '[:space:]')
  if [ -z "$n" ] || ! printf '%s' "$n" | grep -qE '^[0-9]+$'; then
    DETALLE="no existe la tabla alumnos (o no se puede consultar)"
    return 1
  fi
  if [ "$n" -ge 3 ]; then
    DETALLE="tabla alumnos con $n filas"
    return 0
  fi
  # ¿Hay otra tabla con datos? El alumno pudo llamarla de otra forma
  local t c
  for t in $(psqlq "SELECT tablename FROM pg_tables WHERE schemaname='public'" | tr -d ' '); do
    c=$(psqlq "SELECT COUNT(*) FROM \"$t\"" | head -1 | tr -d '[:space:]')
    if [ -n "$c" ] && printf '%s' "$c" | grep -qE '^[0-9]+$' && [ "$c" -ge 3 ]; then
      DETALLE="tabla '$t' con $c filas (el enunciado pedía 'alumnos')"
      return 0
    fi
  done
  if [ -n "$n" ] && printf '%s' "$n" | grep -qE '^[0-9]+$' && [ "$n" -gt 0 ]; then
    PUNTOS_PARCIAL=$(( 20 * n / 3 ))
    DETALLE="la tabla alumnos tiene $n filas (hacen falta 3)"
    return 1
  fi
  DETALLE="no hay ninguna tabla con datos"
  return 1
}

# ── ejecución ──────────────────────────────────────────────────────
INICIO=$(date '+%Y-%m-%d %H:%M')
USUARIO=$(id -un)

if [ "$SOLO_JSON" = 0 ]; then
  echo
  printf "${C}════════════════════════════════════════════════════════════${N}\n"
  printf "${B}  AUTOEVALUACIÓN — Práctica AWS con Floci${N}\n"
  printf "  Alumno: %s   ·   %s\n" "$USUARIO" "$INICIO"
  [ -n "$SOLO_BLOQUE" ] && printf "  Solo bloque: %s\n" "$SOLO_BLOQUE"
  printf "${C}════════════════════════════════════════════════════════════${N}\n\n"
  printf "  %-14s %-8s %s\n" "CRITERIO" "PUNTOS" "DETALLE"
  printf "  %s\n" "──────────────────────────────────────────────────────────"
fi

OBTENIDO=0
TOTAL_POSIBLE=0
DETALLES=""
ESTADOS=""
NOTAS=""
FALLAN=""

i=0
while [ "$i" -lt "${#CRITERIOS[@]}" ]; do
  c="${CRITERIOS[$i]}"
  i=$(( i + 1 ))

  if [ -n "$SOLO_BLOQUE" ] && [ "$(bloque_de "$c")" != "$SOLO_BLOQUE" ]; then
    continue
  fi

  PUNTOS=$(puntos_de "$c")
  PUNTOS_PARCIAL=""
  DETALLE=""
  if "chk_$c"; then NCRIT=$PUNTOS; OK=1; else NCRIT=${PUNTOS_PARCIAL:-0}; OK=0; fi

  OBTENIDO=$(( OBTENIDO + NCRIT ))
  TOTAL_POSIBLE=$(( TOTAL_POSIBLE + PUNTOS ))
  ESTADOS="$ESTADOS$OK "
  DETALLES="${DETALLES}${DETALLE}
"
  NOTAS="$NOTAS$NCRIT "
  [ "$OK" = 0 ] && FALLAN="$FALLAN $(bloque_de "$c")"

  if [ "$SOLO_JSON" = 0 ]; then
    if [ "$OK" = 1 ]; then marca="${V}✓${N}"; else marca="${R}✗${N}"; fi
    printf "  %s %-13s ${B}%2d/%-2d${N}  %s\n" "$marca" "$c" "$NCRIT" "$PUNTOS" "$DETALLE"
  fi
done

if [ "$TOTAL_POSIBLE" -gt 0 ]; then NOTA=$(( OBTENIDO * 100 / TOTAL_POSIBLE )); else NOTA=0; fi

if [ "$SOLO_JSON" = 0 ]; then
  printf "  %s\n" "──────────────────────────────────────────────────────────"
  if [ "$NOTA" -ge 90 ]; then color="$V"; elif [ "$NOTA" -ge 70 ]; then color="$A"; else color="$R"; fi
  if [ -n "$SOLO_BLOQUE" ]; then
    printf "  ${B}BLOQUE %s:${N} ${color}%d/%d${N}\n" "$SOLO_BLOQUE" "$OBTENIDO" "$TOTAL_POSIBLE"
  else
    printf "  ${B}NOTA:${N} ${color}%d/100${N}\n" "$NOTA"
  fi

  if [ -n "$(printf '%s' "$FALLAN" | tr -d ' ')" ]; then
    BLOQUES=$(printf '%s\n' $FALLAN | sort -un | tr '\n' ' ')
    printf "\n  Repasa los bloques: ${A}%s${N}\n" "$BLOQUES"
    printf "  Enunciado: ${C}practica/PRACTICA.md${N}\n"
  elif [ "$TOTAL_POSIBLE" -gt 0 ]; then
    printf "\n  ${V}¡Todo correcto! Puedes entregar con --guardar${N}\n"
  fi
  echo
fi

# ── JSON ───────────────────────────────────────────────────────────
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

JSON_CRIT=""
i=0
while [ "$i" -lt "${#CRITERIOS[@]}" ]; do
  c="${CRITERIOS[$i]}"
  i=$(( i + 1 ))
  if [ -n "$SOLO_BLOQUE" ] && [ "$(bloque_de "$c")" != "$SOLO_BLOQUE" ]; then continue; fi

  PUNTOS=$(puntos_de "$c")
  DET=$(printf '%s' "$DETALLES" | sed -n "${i}p")
  EST=$(printf '%s' "$ESTADOS" | cut -d' ' -f"$i")
  NOT=$(printf '%s' "$NOTAS" | cut -d' ' -f"$i")
  [ -n "$JSON_CRIT" ] && JSON_CRIT="$JSON_CRIT,"
  if [ "$EST" = "1" ]; then OKJ="true"; else OKJ="false"; fi
  JSON_CRIT="$JSON_CRIT\"$c\":{\"puntos\":$NOT,\"max\":$PUNTOS,\"ok\":$OKJ,\"detalle\":\"$(esc "$DET")\"}"
done

JSON="{\"alumno\":\"$USUARIO\",\"fecha\":\"$INICIO\",\"nota\":$NOTA,\"obtenido\":$OBTENIDO,\"posible\":$TOTAL_POSIBLE,\"bloque\":\"${SOLO_BLOQUE:-todos}\",\"criterios\":{$JSON_CRIT}}"

[ "$SOLO_JSON" = 1 ] && printf '%s\n' "$JSON"

# ── entrega ────────────────────────────────────────────────────────
if [ "$GUARDAR" = 1 ]; then
  SELLO=$(date '+%Y%m%d-%H%M')
  DEST="$DIR/entregas/$USUARIO-$SELLO"
  mkdir -p "$DEST" || { echo "No pude crear $DEST" >&2; exit 1; }
  printf '%s\n' "$JSON" > "$DEST/entrega.json"
  {
    echo "Autoevaluación de $USUARIO — $INICIO"
    echo
    i=0
    while [ "$i" -lt "${#CRITERIOS[@]}" ]; do
      c="${CRITERIOS[$i]}"
      i=$(( i + 1 ))
      if [ -n "$SOLO_BLOQUE" ] && [ "$(bloque_de "$c")" != "$SOLO_BLOQUE" ]; then continue; fi
      DET=$(printf '%s' "$DETALLES" | sed -n "${i}p")
      EST=$(printf '%s' "$ESTADOS" | cut -d' ' -f"$i")
      NOT=$(printf '%s' "$NOTAS" | cut -d' ' -f"$i")
      printf '%-14s %2d/%-2d  %-5s %s\n' "$c" "$NOT" "$(puntos_de "$c")" \
        "$([ "$EST" = 1 ] && echo OK || echo FALLO)" "$DET"
    done
    echo
    echo "NOTA: $NOTA/100 ($OBTENIDO de $TOTAL_POSIBLE)"
  } > "$DEST/salida.txt"

  cat > "$DEST/informe.md" <<'EOS'
# Informe de la práctica

**Alumno:** ___
**Fecha:** ___

Responde aquí las 20 preguntas del enunciado (`practica/PRACTICA.md`).
Puedes añadir capturas en esta misma carpeta.

## Bloque 0
1.
2.

## Bloque 1
3.
4.

## Bloque 2
5.
6.

## Bloque 3
7.
8.

## Bloque 4
9.
10.
11.

## Bloque 5
12.
13.

## Bloque 6
14.
15.

## Bloque 7
16.
17.
18.

## Bloque 9
19.
20.
EOS

  echo
  printf "${V}  ✓ Entrega guardada en practica/entregas/%s-%s${N}\n" "$USUARIO" "$SELLO"
  printf "    · entrega.json   (nota y detalle)\n"
  printf "    · salida.txt     (esta salida)\n"
  printf "    · informe.md     (rellena las preguntas)\n\n"
fi
