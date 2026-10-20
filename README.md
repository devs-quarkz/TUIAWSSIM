# TUIAWSSIM

**Práctica guiada de AWS en tu propio portátil, con una interfaz de terminal.**
Crea una instancia EC2 (Linux de verdad) y una base de datos PostgreSQL usando
[Floci](https://github.com/floci-io/floci), un emulador local de AWS. Sin cuenta
de AWS y, una vez descargadas las imágenes, **sin internet**.

Funciona en **Linux Mint**, **Ubuntu** y **macOS**. El script detecta el sistema
operativo y adapta la instalación.

---

## Qué hace

Un solo comando abre un menú que te lleva de la mano:

1. **Comprueba tu equipo** (sistema, Docker, puertos ocupados, internet).
2. **Instala lo que falta**: Docker, la AWS CLI v2 y `psql`.
3. **Descarga las imágenes** y construye la de EC2 con servidor SSH.
4. **Arranca Floci** y configura `~/.aws/config`.
5. **Crea una instancia EC2** y te deja **entrar por SSH** en ella.
6. **Crea una base de datos** PostgreSQL y te enseña a consultarla con SQL.
7. **Limpia** cuando terminas.

Todo lo que crea queda en Docker, `~/awsclase`, `~/.aws` y
`~/floci-practica.log`. No toca nada más de tu equipo.

---

## Instalación rápida (con internet)

```bash
curl -fsSL https://raw.githubusercontent.com/devs-quarkz/TUIAWSSIM/main/instalar.sh | bash
```

Eso descarga el proyecto en `~/TUIAWSSIM`, detecta tu sistema y abre el menú.

Si prefieres clonarlo a mano:

```bash
git clone https://github.com/devs-quarkz/TUIAWSSIM.git ~/TUIAWSSIM
cd ~/TUIAWSSIM
./floci-tui.sh
```

---

## Instalación en clase, SIN internet

El profesor levanta un servidor en su equipo y los alumnos se descargan todo de
él. No hace falta conexión a internet: solo estar en la misma red (o en la misma
red Tailscale).

### 1. En el equipo del profesor

```bash
cd ~/TUIAWSSIM
./servir.sh
```

Te muestra algo así:

```
  Este equipo:   http://192.168.1.50:8000
  Paquete:       http://192.168.1.50:8000/TUIAWSSIM.tar.gz
  Instalador:    http://192.168.1.50:8000/instalar.sh
```

### 2. En el equipo de cada alumno

```bash
curl -fsSL http://192.168.1.50:8000/instalar.sh | bash -s -- --servidor http://192.168.1.50:8000
```

### 3. (Opcional) que el profesor sirva también las imágenes de Docker

Si quieres que no necesiten internet **ni para las imágenes**, en el equipo del
profesor, con Floci ya descargado:

```bash
docker save floci/floci:latest postgres:16.3-alpine alpine:3.21 \
  public.ecr.aws/amazonlinux/amazonlinux:2023 \
  | gzip > ~/TUIAWSSIM/imagenes-floci.tar.gz
```

Y los alumnos, después de instalar, las cargan con:

```bash
docker load < ~/TUIAWSSIM/imagenes-floci.tar.gz
```

---

## Comandos

| Comando | Qué hace |
|---|---|
| `./floci-tui.sh` | Abre el menú interactivo (recomendado) |
| `./floci-tui.sh --auto` | Hace toda la práctica sin preguntar |
| `./floci-tui.sh --auto --limpiar` | La hace y además limpia al terminar |
| `./floci-tui.sh --ayuda` | Muestra la ayuda |
| `./servir.sh [puerto]` | Sirve el proyecto por HTTP para la clase |
| `curl … \| bash` | Descarga e instala desde GitHub |
| `curl … \| bash -s -- --servidor URL` | Descarga e instala desde el profesor |

---

## Requisitos por sistema

### Linux Mint / Ubuntu

El propio script los instala si faltan:

```bash
sudo apt update
sudo apt install -y docker.io unzip postgresql-client
sudo usermod -aG docker "$USER"      # hay que cerrar sesión después
```

Y la AWS CLI v2 con el instalador oficial:

```bash
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip
sudo ./aws/install
```

En ARM (Raspberry, algunos portátiles) el fichero es `awscli-exe-linux-aarch64.zip`.
El script lo detecta solo.

### macOS

```bash
brew install awscli libpq
```

Docker **no** se instala solo: hace falta [Docker Desktop](https://www.docker.com/products/docker-desktop/)
(o `brew install --cask docker`) abierto, porque el script monta su socket.

Para tener los recuadros del menú (opcional):

```bash
brew install whiptail
```

Sin `whiptail` el menú funciona igual, pero en modo texto.

> **Nota para macOS:** las IPs internas de Floci (`172.31.x.x`) no son
> alcanzables desde el Mac porque Docker corre dentro de una máquina virtual.
> El script lo detecta y usa el **puerto publicado** de la instancia para el SSH.

---

## Problemas conocidos (y resueltos por el script)

| Síntoma | Qué pasa |
|---|---|
| `failed to bind host port 127.0.0.1:7070/tcp: address already in use` | **AnyDesk** usa el 7070, que cae dentro del rango de Floci. El script busca el primer puerto libre y lo usa. |
| `permission denied … docker.sock` | No has cerrado sesión tras el `usermod`. El script usa `sudo docker` mientras tanto. |
| `ssh: Connection closed` justo tras crear la instancia | El `sshd` de dentro tarda **entre 20 s y casi 1 minuto**. El script reintenta hasta 3 minutos. |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | IP reciclada de una prueba anterior: `ssh-keygen -f ~/.ssh/known_hosts -R <IP>`. |
| Un comando `aws` se queda "colgado" | Es el paginador `less`. El script configura `cli_pager` vacío para evitarlo. |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` al segundo intento | La instancia nueva reutiliza la IP. |

---

## Estructura

```
TUIAWSSIM/
├── floci-tui.sh        ← el menú y toda la lógica (multi-SO)
├── instalar.sh         ← descarga el proyecto y lanza el TUI
├── servir.sh           ← servidor HTTP para clase sin internet
├── docs/
│   └── guia-practica.md  ← la práctica explicada paso a paso
└── README.md
```

---

## Probado en

- Linux Mint 22.3 (Docker 29.9.1, psql 16.15) — bloques 2 a 7 completos
- Ubuntu 24.04.4 LTS (Docker 29.1.3, psql 16.15)
- macOS (por probar en la versión publicada)

Floci: probado con la 2.2.0 y la 2.3.0.

---

## Sobre Floci

Floci no se instala: **se ejecuta** como contenedor. La API escucha en el puerto
4566 y **no tiene autenticación**, por eso la práctica publica los puertos solo en
`127.0.0.1` y nunca en todas las interfaces.

Para que funcione, el contenedor necesita el socket de Docker montado
(`-v /var/run/docker.sock:/var/run/docker.sock`): así crea las instancias EC2 y
las bases de datos como contenedores de verdad.

---

## Licencia

Uso educativo. Haz lo que quieras con él.
