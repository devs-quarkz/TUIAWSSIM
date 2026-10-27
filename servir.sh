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

# ── Página de descarga para los alumnos ────────────────────────────
{
  echo '<!doctype html><meta charset="utf-8"><title>TUIAWSSIM — práctica de AWS</title>'
  echo '<body style="font-family:system-ui;background:#0f1117;color:#e6e6e6;max-width:820px;margin:40px auto;padding:0 20px;line-height:1.5">'
  echo '<h1 style="color:#4cc2ff">TUIAWSSIM</h1>'
  echo '<p>Práctica de AWS en tu portátil. <b>Necesitas estar en la misma red que este equipo</b> (no hace falta internet).</p>'
  echo '<h2>Instalar y empezar</h2>'
  echo "<pre style=\"background:#1a1d27;padding:14px;border-radius:8px;overflow:auto\">curl -fsSL http://$IP:$PUERTO/instalar.sh | bash -s -- --servidor http://$IP:$PUERTO</pre>"
  echo '<p>Si prefieres hacerlo a mano, descarga el proyecto y ejecútalo:</p>'
  echo '<ul>'
  for f in TUIAWSSIM.tar.gz offline/TUIAWSSIM.tar.gz offline/MANIFIESTO.txt; do
    [ -f "$DIR/$f" ] && echo "<li><a style=\"color:#4cc2ff\" href=\"/$f\">$f</a> ($(du -h "$DIR/$f" | cut -f1))</li>"
  done
  [ -d "$DIR/offline" ] && echo "<li><b>offline/</b> — todo lo necesario para instalar sin internet</li>"
  echo '</ul>'
  echo '<p style="color:#888">Servido por '"$(hostname)"' · puerto '"$PUERTO"'</p>'
} > "$DIR/index.html"

cd "$DIR" || exit 1
exec python3 -m http.server "$PUERTO" --bind 0.0.0.0
