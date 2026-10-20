#!/usr/bin/env bash
#
# servir.sh — levanta un servidor HTTP con este proyecto para clase sin internet.
# Los alumnos descargan desde aquí en vez de GitHub.
#
# Funciona en Linux (Mint/Ubuntu) y macOS.
#
#   ./servir.sh            → puerto 8000
#   ./servir.sh 9000       → otro puerto
#
set -o pipefail

PUERTO="${1:-8000}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# ── IP local ─────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin)
    IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)"
    ;;
  *)
    IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
    [ -z "$IP" ] && IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    ;;
esac
[ -z "$IP" ] && IP="127.0.0.1"

command -v python3 >/dev/null 2>&1 || {
  printf '\033[1;31m  Necesito python3 para servir los ficheros.\033[0m\n'
  printf '  Linux: sudo apt install -y python3\n  macOS: viene instalado\n'
  exit 1
}

# ── Paquete para descargar ───────────────────────────────────
printf '  Preparando el paquete…\n'
TMP="$(mktemp -d)"
mkdir -p "$TMP/TUIAWSSIM"
cp -R "$DIR"/. "$TMP/TUIAWSSIM"/ 2>/dev/null
rm -f "$TMP/TUIAWSSIM/TUIAWSSIM.tar.gz"
tar -czf "$DIR/TUIAWSSIM.tar.gz" -C "$TMP" TUIAWSSIM
rm -rf "$TMP"
printf '  Paquete listo: %s (%s)\n\n' "$DIR/TUIAWSSIM.tar.gz" "$(du -h "$DIR/TUIAWSSIM.tar.gz" | cut -f1)"

# ── Instrucciones y servidor ─────────────────────────────────
cat <<EOF
═══════════════════════════════════════════════════════════════
  TUIAWSSIM — servidor de clase
═══════════════════════════════════════════════════════════════

  Este equipo:   http://$IP:$PUERTO
  Paquete:       http://$IP:$PUERTO/TUIAWSSIM.tar.gz
  Instalador:    http://$IP:$PUERTO/instalar.sh

  ── Pásale esto a tus alumnos ──────────────────────────────

  curl -fsSL http://$IP:$PUERTO/instalar.sh | bash -s -- --servidor http://$IP:$PUERTO

  ───────────────────────────────────────────────────────────

  Los alumnos deben estar en la misma red (o en tu red Tailscale).
  Para parar el servidor: Ctrl+C

  Si no cargan la página, revisa el cortafuegos:
    Linux:  sudo ufw allow $PUERTO/tcp
    macOS:  Ajustes → Red → Cortafuegos → permitir python3

═══════════════════════════════════════════════════════════════

EOF

cd "$DIR" || exit 1
exec python3 -m http.server "$PUERTO" --bind 0.0.0.0
