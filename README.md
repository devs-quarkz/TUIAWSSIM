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

> [!IMPORTANT]
> El comando de abajo **solo funciona si el repositorio es público**. Si está
> privado, usa el servidor del profesor (siguiente sección) o clona con
> `git clone git@github.com:...`.

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

### 1. En el equipo del profesor (una vez, este sí con red)

```bash
cd ~/TUIAWSSIM
./preparar-offline.sh
```

Descarga y empaqueta **todo lo que hace falta para instalar sin red**:

- los `.deb` de Docker, containerd, unzip y el cliente de PostgreSQL, **con sus
  dependencias** (unos 88 MB),
- el instalador de la AWS CLI v2 (~72 MB),
- las 4 imágenes de Docker (~262 MB comprimidas),
- el propio proyecto,

y lo junta en `offline/` más un único `offline.tar.gz` (~415 MB) que es lo que se
bajan los alumnos.

### 2. Servir la clase

> **Si Floci no responde** en el equipo del alumno (el contenedor está `healthy`
> pero `curl localhost:4566` falla), mira el cortafuegos: algunas configuraciones
> de `ufw`/`iptables` bloquean el loopback o la red de Docker. En una Ubuntu con
> `ufw` normal no pasa; si lo tocaste, `sudo ufw allow in on lo` y
> `sudo ufw allow out on lo`.

> **Si los alumnos no cargan la página**, es casi siempre el cortafuegos del
> profesor: `sudo ufw allow 8000/tcp` (Ubuntu/Mint). En macOS, permitir `python3`
> en Ajustes → Red → Cortafuegos. El SSH puede funcionar y el 8000 no, así que
> pruébalo desde otro equipo antes de la clase.

```bash
./servir.sh
```

Te muestra algo así:

```
  Este equipo:   http://192.168.1.50:8000
  Paquete:       http://192.168.1.50:8000/TUIAWSSIM.tar.gz
  Instalador:    http://192.168.1.50:8000/instalar.sh
```

### 3. En el equipo de cada alumno

```bash
curl -fsSL http://192.168.1.50:8000/instalar.sh | bash -s -- --servidor http://192.168.1.50:8000
```

### 4. Qué pasa en el equipo del alumno

El instalador se baja el proyecto **y** `offline.tar.gz` (si el profesor lo
sirve) y lo deja en `offline/`. Luego el TUI, cuando le falta algo:

| Le falta | Lo instala con |
|---|---|
| Docker | `dpkg -i` de los `.deb` del paquete |
| AWS CLI | `unzip` del instalador del paquete |
| psql | `dpkg -i` de los `.deb` del paquete |
| Imágenes | `docker load` de `offline/imagenes-floci.tar.gz` |
| Imagen de EC2 | viaja ya construida (con el arreglo de PAM) |

Sin internet no hay `apt update`, ni `docker pull`, ni `docker build`: todo sale
del paquete. Se puede forzar el modo sin red para probarlo:

```bash
./floci-tui.sh --sin-internet
```

Si prefieres pasar solo las imágenes a mano:

```bash
./floci-tui.sh --exportar /ruta/paquete.tar.gz    # profesor
./floci-tui.sh --cargar   /ruta/paquete.tar.gz    # alumnos
```

Si prefieres hacerlo a mano:

```bash
./floci-tui.sh --exportar /ruta/paquete.tar.gz    # en el equipo del profesor
./floci-tui.sh --cargar   /ruta/paquete.tar.gz    # en el de los alumnos
```

En ese caso la imagen de EC2 viaja ya construida (con el arreglo de PAM), así que
los alumnos **ni descargan 1 GB ni ejecutan el `docker build`**.

---

## Roles: alumno y profesor

Al arrancar, el TUI pregunta **quién eres** (lo recuerda en `~/.tuiawssim-rol`;
se cambia desde «Cambiar de rol» o con `--alumno` / `--profesor`).

**Menú del ALUMNO** — cuatro opciones:

| | |
|---|---|
| 1 | Hacer la práctica (te guía y te corrige) |
| 2 | Mi nota y entregar |
| 3 | Ayuda (diagnóstico, log, SSH, SQL, limpiar, cambiar de rol) |
| 0 | Salir |

**Menú del PROFESOR** — cuatro opciones:

| | |
|---|---|
| 1 | Preparar y servir la clase |
| 2 | Ver entregas |
| 3 | Probar este equipo (demo) |
| 4 | Herramientas (instalar, exportar, limpiar, desinstalar Docker, log…) |
| 0 | Salir |

Lo de todos los días está en el menú; lo de mantenimiento, dentro de «Ayuda» o
«Herramientas».


## La práctica del alumno

El TUI tiene **dos modos**:

| Opción | Para qué |
|---|---|
| **1 — ALUMNO** | El TUI guía bloque a bloque, pero **los comandos los escribe el alumno** en otra terminal. Aquí se aprende. |
| **2 — PROFESOR** | Demo automática: instala, arranca y hace toda la práctica sola. Para enseñar en clase o comprobar un equipo. |

### El enunciado

`practica/PRACTICA.md` — 10 bloques con objetivo, comandos, salida esperada,
un comando de comprobación y **20 preguntas** para el informe:

| Bloque | Tema |
|---:|---|
| 0 | Comprueba tu equipo (Docker) |
| 1 | Arranca Floci y configura AWS |
| 2 | Tu llave SSH |
| 3 | Crea la instancia EC2 |
| 4 | Entra por SSH |
| 5 | Crea la base de datos (RDS) |
| 6 | Conéctate con `psql` |
| 7 | Tu primera tabla (CREATE/INSERT/SELECT/UPDATE/DELETE) |
| 8 | Autoevalúa y entrega |
| 9 | Limpia tu equipo |

### La calificación automática

`practica/verificar.sh` mira el estado real del equipo (no apuntes) y puntúa
sobre 100:

| Criterio | Puntos |
|---|---:|
| Entorno (Docker responde) | 10 |
| Floci sano | 10 |
| Credenciales (`000000000000`) | 5 |
| Imagen de EC2 preparada | 5 |
| Llave `.pem` con permisos 400 | 5 |
| Instancia en marcha | 10 |
| **Entrar por SSH** | 15 |
| Base de datos disponible | 10 |
| Conexión con `psql` | 10 |
| **Tabla `alumnos` con 3 filas** | 20 |

```bash
./practica/verificar.sh              # tabla con la nota, sin tocar nada
./practica/verificar.sh --bloque 4   # solo el bloque 4 (SSH)
./practica/verificar.sh --guardar    # además guarda la entrega
```

Funciona con **bash 3.2** (el de macOS) y en Linux.

### La entrega

`--guardar` (o la opción 12 del menú) crea
`practica/entregas/<usuario>-<fecha>/` con:

- `entrega.json` — nota y detalle de cada criterio
- `salida.txt` — la salida del verificador
- `informe.md` — plantilla con las 20 preguntas

El profesor las lista con la **opción 13** del menú:

```
  ALUMNO-FECHA               NOTA  CONTENIDO
  ──────────────────────────────────────────────────────
  alejandro-20261028-2101    95    entrega.json informe.md salida.txt
```

Desde la línea de comandos:

```bash
./floci-tui.sh --autoevaluar    # puntúa y sale
./floci-tui.sh --entregar       # puntúa y guarda la entrega
```

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
| `SUDO_PASS=… ./floci-tui.sh --auto` | Igual, pero sin que pida la contraseña de sudo |

---

### El TUI lo instala todo (incluido Docker)

No hace falta preparar nada antes: el TUI instala lo que falte y te pide la
contraseña **en su propia ventana** cuando hace falta (sudo).

- **Linux**: `docker.io`, `unzip`, `postgresql-client` y la AWS CLI v2.
- **macOS**: Rosetta 2 si falta, Docker Desktop (o Colima), `awscli` y `libpq`
  con Homebrew, y arranca el daemon esperando a que responda.
- Comprueba que los programas **funcionan** (no solo que existan): un `psql`
  roto se reinstala.

### Instalar sin que pregunte la contraseña

Si lanzas el script desde otro script, un cron o una herramienta de despliegue,
no hay terminal donde escribir la contraseña de `sudo`. Puedes pasarla así:

```bash
SUDO_PASS='tu_contraseña' ./floci-tui.sh --auto
```

Solo se usa para los `apt install`, no se guarda en ningún sitio.

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

Docker se puede instalar de dos formas, y el TUI te pregunta cuál:

```bash
./floci-tui.sh                 # pregunta: Colima o Docker Desktop
DOCKER_MAC=colima  ./floci-tui.sh   # fuerza Colima
DOCKER_MAC=desktop ./floci-tui.sh   # fuerza Docker Desktop
```

- **Colima** (recomendado): ligero, de terminal, sin app. El TUI hace
  `brew install docker colima` y `colima start`. Probado en macOS arm64.
- **Docker Desktop**: la app oficial, `brew install --cask docker`. Hay que
  abrirla una vez.

### Qué funciona en macOS (probado)

**Docker Desktop: la práctica completa** ✓, incluido el SSH, en macOS arm64:

| | |
|---|---|
| Docker Desktop 4.96 / motor 29.9.1 | ✓ |
| Rosetta 2 para contenedores x86_64 | ✓ (el sshd de la imagen es x86_64) |
| Floci 2.3.0 | ✓ |
| Instancias EC2 | ✓ |
| **SSH a la instancia** | ✓ (`PRETTY_NAME="Amazon Linux 2023"`, usuario `root`, en ~21 s) |
| **PostgreSQL + `psql`** | ✓ (16.3 arm64, tabla con datos) |

**Con Colima NO funciona el SSH** (el resto sí): el sshd de la instancia rechaza
la clave dentro de la VM de Lima. Si usas macOS, elige **Docker Desktop**.

En el Mac hay que tener en cuenta dos cosas que el TUI ya hace solo:
- los binarios de Docker Desktop están dentro de la app
  (`/Applications/Docker.app/Contents/Resources/bin`);
- el socket está en `~/.docker/run/docker.sock`, **no** en `/var/run/docker.sock`.

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

- Linux Mint 22.3 **desde cero** (sin Docker ni AWS CLI): el TUI instaló todo,
  hizo la práctica completa y limpió — sin un solo error
- Ubuntu 24.04.4 LTS (Docker 29.1.3, psql 16.15)
- **macOS 27.0.1 arm64 con Docker Desktop 4.96** (motor 29.9.1) y Rosetta 2:
  el TUI completo con `--auto --limpiar`, sin un solo error — Floci, instancia
  EC2, **SSH dentro de la instancia** (~36 s) y PostgreSQL 16.3 con datos

Floci: probado con la 2.2.0 y la 2.3.0.

---

### Lo que NO funciona: Podman

Podman expone una API compatible con Docker, pero **Floci no funciona con Podman**.
Probado en Ubuntu 24.04 con Podman 4.9.3, tanto rootless como rootful y con
`--privileged`:

```
java.net.BindException: Permission denied
WARN  Ec2ContainerManager - No Docker daemon is reachable from Floci
EC2 instances are emulated as metadata only: ... have no backing container,
so SSH, UserData and SSM command execution stay unavailable
```

Las instancias aparecen como `running` pero con `PublicIpAddress: None`, no se
crea ningún contenedor y el SSH y la base de datos no funcionan. El TUI avisa si
detecta que tu `docker` es en realidad Podman.

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
