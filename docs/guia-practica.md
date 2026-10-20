# La práctica, paso a paso

> Versión en texto de la práctica. La versión con capturas está en Obsidian.
>
> Para hacerla en tu equipo lo más fácil es usar el TUI:
>
> ```bash
> ./floci-tui.sh
> ```
>
> Él instala lo que falte y te va guiando.

# Floci — la práctica completa, paso a paso

> Qué es esta nota
> La práctica entera, **desde el bloque 0**, con cada paso y su captura al lado.
>
> Las capturas son las salidas reales de una sesión ejecutada sobre Ubuntu 24.04.4 LTS, presentadas en una terminal limpia para que se lean bien en el móvil o en el proyector.
>
> **Validada también en Linux Mint 22.3** (la máquina del aula) el 19 de octubre de 2026, con Floci 2.3.0: bloques 2 a 7 completos, SSH dentro de la instancia y base de datos con datos. De ahí salieron dos avisos nuevos: el conflicto de puertos con AnyDesk y que el `sshd` puede tardar casi un minuto.
>
> **Los bloques 0 a 2 se hacen en casa** (necesitan internet). **Los bloques 3 a 7 se hacen en clase, sin conexión.**

---

# Bloque 0 — Instalar Docker

### 0.1 — Actualizar los índices de paquetes

```bash
sudo apt update
```


### 0.2 — Instalar Docker

```bash
sudo apt install -y docker.io
```


Instala Docker **y `containerd`** (son 61 MB). Al terminar verás que deja el servicio habilitado:

```
Created symlink /etc/systemd/system/multi-user.target.wants/docker.service …
```

### 0.3 — Darte permiso para usar Docker sin `sudo`

```bash
sudo usermod -aG docker $USER
```

> Esto no surte efecto hasta que vuelvas a entrar
> Los grupos se asignan **al iniciar sesión**, así que hay que **cerrar sesión en el escritorio y volver a entrar**. Recargar el `.zshrc` o abrir otra pestaña **no sirve**.
> *(Atajo sin cerrar sesión: `newgrp docker`, pero solo afecta a esa terminal.)*

### 0.4 — Comprobar que funciona

```bash
docker run --rm hello-world
```


**Lo que debe salir:** `Hello from Docker!`.

> Si sale `permission denied … Docker daemon socket`
> Es que no has cerrado sesión después del `usermod` (paso 0.3). Cierra sesión del escritorio y vuelve a entrar.

---

# Bloque 1 — Las herramientas cliente

### 1.1 — El cliente de PostgreSQL y `unzip`

```bash
sudo apt install -y unzip postgresql-client
```

### 1.2 — La AWS CLI v2

Primero se detecta si el procesador es Intel/AMD o ARM:

```bash
case $(uname -m) in aarch64|arm64) A=aarch64 ;; *) A=x86_64 ;; esac
```

```bash
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-$A.zip" -o awscliv2.zip
```

```bash
unzip awscliv2.zip
```

```bash
sudo ./aws/install
```

> El paquete `awscli` de apt NO sirve
> En Ubuntu 24.04 no existe (en 22.04 sí, pero es la versión 1, demasiado antigua para esta práctica). Hay que usar el instalador oficial.

### 1.3 — Comprobar las dos

```bash
aws --version
```

```bash
psql --version
```


**Evidencia para el profesor:** pide esta captura antes de la clase. Si aquí no aparecen las dos versiones, en el aula ya no se puede arreglar, porque no hay internet.

---

# Bloque 2 — Preparar las imágenes

### 2.1 — Descargar la imagen base de EC2

```bash
docker pull public.ecr.aws/amazonlinux/amazonlinux:2023
```


### 2.2 — Añadirle el servidor SSH

```bash
docker build -t public.ecr.aws/amazonlinux/amazonlinux:2023 - <<'DF'
FROM public.ecr.aws/amazonlinux/amazonlinux:2023
RUN dnf install -y openssh-server openssh-clients && dnf clean all
RUN sed -i /account/d /etc/pam.d/sshd
RUN echo account required pam_permit.so >> /etc/pam.d/sshd
DF
```


> Las dos líneas de PAM van separadas a propósito
> La primera borra **todas** las líneas `account` del fichero PAM y la segunda pone una sola que siempre permite el acceso. Si se dejan las originales, el SSH falla con `Connection closed` **sin decir por qué**.
> Escríbelas tal cual: sin `^` y sin comillas.

### 2.3 — Verificar la imagen

```bash
docker run --rm public.ecr.aws/amazonlinux/amazonlinux:2023 sh -c 'grep account /etc/pam.d/sshd; ls /usr/sbin/sshd'
```


> Punto de control del bloque 2
> Debe salir **una sola** línea `account required pam_permit.so` y la ruta `/usr/sbin/sshd`. Si aparece más de una línea `account`, la imagen está mal y el SSH fallará en clase.

---

# Bloque 3 — Arrancar Floci

### 3.1 — Desactivar el paginador

```bash
aws configure set cli_pager ""
```

> Hazlo antes de nada
> La AWS CLI v2 abre `less` con cualquier tabla. Sin esto, en cuanto un alumno ejecute `aws ec2 describe-instances` se queda atascado en una pantalla de ayuda sin saber salir. Si ya ha pasado: **pulsa `q`**.

### 3.2 — Arrancar el contenedor

```bash
docker run -d --name floci \
  -p 127.0.0.1:4566:4566 \
  -p 127.0.0.1:7001-7099:7001-7099 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e FLOCI_SERVICES_UI_ENABLED=false \
  -e FLOCI_DNS_CONTAINER_FALLBACK_ENABLED=false \
  floci/floci:latest
```


> Si falla con `port is already in use`
> El rango 7001-7099 puede chocar con algo que ya esté escuchando ahí. **El culpable más frecuente es AnyDesk, que usa el 7070** — comprobado en un Linux Mint 22.3:
> `failed to bind host port 127.0.0.1:7070/tcp: address already in use`
>
> Comprueba quién lo ocupa y publica solo el puerto de la primera base de datos, que para esta práctica basta:
> ```bash
> sudo ss -ltnp | grep -E ":70[0-9][0-9]"
> ```
> ```bash
> docker run -d --name floci \
>   -p 127.0.0.1:4566:4566 \
>   -p 127.0.0.1:7001:7001 \
>   -v /var/run/docker.sock:/var/run/docker.sock \
>   -e FLOCI_SERVICES_UI_ENABLED=false \
>   -e FLOCI_DNS_CONTAINER_FALLBACK_ENABLED=false \
>   floci/floci:latest
> ```
> La base de datos sigue apareciendo en `localhost:7001` y todo lo demás no cambia.

### 3.3 — Comprobar que responde

```bash
curl -s http://localhost:4566/_floci/health
```


### 3.4 — Test de aceptación

```bash
aws sts get-caller-identity
```


**Lo que debe salir:** `"Account": "000000000000"`. Nadie pasa al bloque 4 sin verlo.

---

# Bloque 4 — La instancia EC2

```bash
mkdir -p ~/awsclase
```

```bash
aws ec2 create-key-pair --key-name clase --query KeyMaterial --output text > ~/awsclase/clase.pem
```

```bash
chmod 400 ~/awsclase/clase.pem
```

```bash
aws ec2 run-instances --image-id ami-0abcdef1234567891 --instance-type t2.micro --key-name clase
```


```bash
aws ec2 describe-instances --query 'Reservations[].Instances[].{ID:InstanceId,Estado:State.Name,IP:PublicIpAddress}' --output table
```


**Lo que debe salir:** `running`. La instancia ya existe: es un contenedor de verdad.

---

# Bloque 5 — Entrar por SSH

```bash
IP=$(aws ec2 describe-instances --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
```

```bash
ssh -o StrictHostKeyChecking=no -i ~/awsclase/clase.pem root@$IP
```

```bash
cat /etc/os-release
```

```bash
whoami
```


**Fíjate en dos cosas:** el prompt cambia a `root@…` y `PRETTY_NAME` dice **Amazon Linux 2023**. Si ahí ves "Ubuntu", es que el SSH no entró y sigues en tu máquina.

> Si tarda o falla
> - `Connection closed` o `refused`: el `sshd` de dentro tarda en arrancar, **entre 20 s y casi un minuto** según la máquina (en un Mint 22.3 medido: ~57 s). Reintenta sin prisa.
> - `REMOTE HOST IDENTIFICATION HAS CHANGED`: es una IP reciclada. `ssh-keygen -f ~/.ssh/known_hosts -R <IP>` y reintenta.
>
> Para volver a tu máquina: `exit`.

---

# Bloque 6 — La base de datos

### 6.1 — Crearla

```bash
aws rds create-db-instance --db-instance-identifier clase-db --engine postgres \
  --db-instance-class db.t3.micro --master-username admin \
  --master-user-password secreto123 --allocated-storage 20
```


### 6.2 — Ver el endpoint

```bash
aws rds describe-db-instances --query 'DBInstances[].{ID:DBInstanceIdentifier,Estado:DBInstanceStatus,Motor:Engine,Host:Endpoint.Address,Puerto:Endpoint.Port}' --output table
```


> El `Host` que devuelve es interno
> Verás una IP tipo `172.17.0.2`. **No la uses**: conéctate siempre por `localhost` y el puerto `7001`, que es el que Floci publica en tu máquina.

### 6.3 — Conectar con psql

```bash
psql -h localhost -p 7001 -U admin -d postgres
```

Contraseña: `secreto123`.

```sql
SELECT version();
```


> `psql` tiene paginador, como la AWS CLI
> Manda los resultados a `less`. Si el paginador falla, **la consulta parece no devolver nada**: te queda un prompt vacío y ningún error que lo explique. Dos formas de evitarlo:
> - Al conectar: `psql -P pager=off -h localhost -p 7001 -U admin -d postgres`
> - Ya dentro: `\pset pager off` (contesta `Pager usage is off.`)
>
> En la captura está hecho de la segunda forma, y la consulta va en una sola línea con `-c` para que se vea el resultado completo.

### 6.4 — Crear una tabla y consultarla

Dentro de la misma sesión de `psql`:

```sql
CREATE TABLE alumnos (id SERIAL PRIMARY KEY, nombre VARCHAR(50), nota NUMERIC(4,2));
```

```sql
INSERT INTO alumnos (nombre, nota) VALUES ('Ana', 8.5), ('Luis', 6.0), ('Marta', 9.25);
```

```sql
SELECT * FROM alumnos;
```

```sql
\q
```


> Si prefieres no teclearlo a mano
> Las sentencias largas son donde más se falla: una coma que se pierde deja la orden a medias, el prompt cambia de `postgres=#` a **`postgres-#`**, y **todo lo que escribas después se acumula dentro de la misma orden**. Se sale con `Ctrl+C`.
> También puedes dejarlas en un fichero y ejecutarlo de una vez:
> ```bash
> psql -P pager=off -h localhost -p 7001 -U admin -d postgres -f /tmp/consultas.sql
> ```

---

# Bloque 7 — Limpiar

```bash
aws ec2 terminate-instances --instance-ids $(aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId' --output text)
```

```bash
aws rds delete-db-instance --db-instance-identifier clase-db --skip-final-snapshot
```

```bash
docker rm -f floci
```


---

## Resumen

| Bloque | Qué se hace | Dónde | ¿Red? | Capturas |
|---|---|---|---|---|
| 0 | Instalar Docker | Casa | Sí | 00, 01, 02 |
| 1 | Instalar AWS CLI v2 y `psql` | Casa | Sí | 03 |
| 2 | Descargar las imágenes y construir la de EC2 | Casa | Sí | 04, 05, 06 |
| 3 | Arrancar Floci y el test de aceptación | Clase | No | 07, 08, 09 |
| 4 | Llave, instancia y estado | Clase | No | 10, 11 |
| 5 | SSH dentro de la instancia | Clase | No | 12 |
| 6 | Base de datos y consultas SQL | Clase | No | 13, 14, 15, 16 |
| 7 | Limpieza | Clase | No | 17 |

> Lo que demuestra la práctica
> La instancia es un contenedor real al que entras por SSH y ves **Amazon Linux 2023**, y la base de datos es un PostgreSQL real en el que creas una tabla, insertas filas y las consultas. Todo sin salir del portátil y, a partir del bloque 3, sin internet.

---

*Guía de referencia con las notas para el docente: la guía del profesor · Capturas de una sesión sobre Ubuntu 24.04.4 LTS (Floci 2.2.0) · Flujo validado también en Linux Mint 22.3 con Floci 2.3.0.*
