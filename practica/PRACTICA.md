# Práctica: una nube de AWS en tu portátil

**Materia:** ___ · **Alumno:** ___ · **Fecha:** ___

Vas a levantar tu propia "nube" con **Floci** (un emulador de AWS que corre en
Docker) y a usarla como si fuera AWS de verdad: crearás una instancia, entrarás
por SSH y montarás una base de datos PostgreSQL.

No hace falta cuenta de AWS, ni tarjeta, ni internet: todo ocurre en tu equipo.

---

## Cómo se trabaja

Cada bloque tiene cuatro partes:

| | |
|---|---|
| **Objetivo** | qué vas a conseguir |
| **Escribes tú** | los comandos, uno a uno. No los copies a ciegas: léelos |
| **Deberías ver** | la salida esperada, para que sepas si vas bien |
| **Comprueba** | un comando que verifica ese bloque |

Al final de cada bloque hay **preguntas**. Las respuestas van en tu informe.

> **Regla de oro:** si un comando falla, no sigas. Lee el error, arréglalo y
> vuelve a intentarlo. Aprender a leer el error es la mitad de la práctica.

Cuando termines los bloques 0 a 7, ejecuta el autoevaluador:

```bash
./practica/verificar.sh
```

Te dará una nota sobre 100 y te dirá qué bloque te falta. Cuando esté todo bien:

```bash
./practica/verificar.sh --guardar
```

Eso deja tu entrega en `practica/entregas/`.

---

## Bloque 0 — Comprueba tu equipo

**Objetivo:** saber si tienes Docker funcionando y qué versión.

Docker es quien ejecutará Floci y las "máquinas" que vas a crear.

### Escribes tú

```bash
docker --version
```

```bash
docker info --format '{{.ServerVersion}} · {{.OperatingSystem}} · {{.Architecture}}'
```

### Deberías ver

Algo como `Docker version 29.x` y, en la segunda, el servidor, el sistema y la
arquitectura (`linux/amd64` o `linux/arm64`).

### Comprueba

```bash
docker run --rm hello-world
```

Si aparece `Hello from Docker!`, tu Docker está sano. Si dice
`permission denied` al socket, cierra la sesión y vuelve a entrar (te falta el
grupo `docker`).

### Preguntas

1. ¿Qué diferencia hay entre `docker --version` y `docker info`?
2. ¿Qué es un contenedor y en qué se diferencia de una máquina virtual?

---

## Bloque 1 — Arranca Floci y configura AWS

**Objetivo:** tener tu "AWS" escuchando en `localhost:4566`.

Floci emula la API de AWS. El puerto **4566** es donde responde, y el **7001** lo
usaremos luego para la base de datos.

### Escribes tú

```bash
docker run -d --name floci -p 127.0.0.1:4566:4566 -p 127.0.0.1:7001:7001 -v /var/run/docker.sock:/var/run/docker.sock -e FLOCI_SERVICES_UI_ENABLED=false -e FLOCI_DNS_CONTAINER_FALLBACK_ENABLED=false floci/floci:latest
```

```bash
docker ps --filter name=floci --format '{{.Names}}  {{.Status}}  {{.Ports}}'
```

```bash
curl -s http://localhost:4566/_floci/health
```

### Deberías ver

El contenedor `Up` y un JSON con `"version":"2.3.0"` y la lista de servicios
(`ec2`, `rds`, `s3`…).

> **¿Por qué `-v /var/run/docker.sock`?** Porque Floci crea contenedores de
> verdad (la instancia EC2 y la base de datos), y para eso necesita hablar con
> el Docker de tu equipo. En macOS ese socket está en `~/.docker/run/docker.sock`.

### Ahora configura el cliente de AWS

El cliente `aws` necesita credenciales. En un emulador son inventadas, pero el
formato es el mismo que en AWS real.

```bash
aws configure set aws_access_key_id test
```

```bash
aws configure set aws_secret_access_key test
```

```bash
aws configure set region us-east-1
```

```bash
aws configure set output json
```

```bash
aws configure set endpoint_url http://localhost:4566
```

```bash
aws configure set cli_pager ""
```

### Comprueba

```bash
aws sts get-caller-identity
```

### Deberías ver

```json
{"UserId": "...", "Account": "000000000000", "Arn": "..."}
```

**`000000000000`** es la cuenta de mentira del emulador. Si te sale otra cosa, el
cliente está hablando con AWS de verdad o con otro sitio: revisa el endpoint.

### Preguntas

3. ¿Qué hace `aws configure set endpoint_url`? ¿Por qué es la clave de todo?
4. El paginador (`cli_pager`) se desactiva. ¿Qué pasaba antes y por qué molesta?

---

## Bloque 2 — Tu llave SSH

**Objetivo:** crear un par de llaves y guardar la privada en tu equipo.

En AWS real, cuando creas una instancia eliges una llave para entrar. AWS se
queda la pública y a ti te da la privada **una sola vez**.

### Escribes tú

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
ls -l ~/awsclase/clase.pem
```

```bash
aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output table
```

### Deberías ver

Un fichero de unos 1600-1700 bytes con permisos `-r--------` (400) y la llave
`clase` en la tabla.

> **El `chmod 400` no es opcional.** SSH se niega a usar una llave que otros
> puedan leer. Es el error más común de esta práctica.

### Preguntas

5. ¿Qué diferencia hay entre la llave pública y la privada? ¿Cuál viaja a AWS?
6. ¿Por qué el `.pem` no debe estar en un repositorio de git?

---

## Bloque 3 — Crea la instancia EC2

**Objetivo:** lanzar tu "servidor" y verlo en marcha.

### Escribes tú

```bash
aws ec2 run-instances --image-id ami-0abcdef1234567891 --instance-type t2.micro --key-name clase
```

```bash
aws ec2 describe-instances --query "Reservations[].Instances[].{ID:InstanceId,Estado:State.Name,Tipo:InstanceType,IP:PublicIpAddress}" --output table
```

### Deberías ver

Una tabla con tu instancia en estado `running` y una IP del tipo `172.31.x.x` (o
`127.0.0.1` en macOS).

### Preguntas

7. ¿Qué es una AMI? ¿Y un tipo de instancia como `t2.micro`?
8. ¿Por qué la IP es privada (`172.31.x.x`) y no una pública?

---

## Bloque 4 — Entra por SSH

**Objetivo:** conectarte a tu instancia como si fuera un servidor remoto.

Primero mira en qué puerto de tu equipo se publica el SSH de la instancia:

```bash
docker ps --filter name=floci-aws-ec2 --format '{{.Names}}  {{.Ports}}'
```

Verás algo como `0.0.0.0:2200->22/tcp`: el **2200** de tu equipo va al **22** de
la instancia.

### Escribes tú

```bash
ssh -p 2200 -i ~/awsclase/clase.pem root@localhost
```

Si en tu caso la IP de la instancia es alcanzable, también vale:

```bash
ssh -i ~/awsclase/clase.pem root@172.31.32.10
```

Dentro de la instancia, prueba:

```bash
cat /etc/os-release
```

```bash
whoami
```

```bash
hostname
```

```bash
dnf --version
```

```bash
exit
```

### Deberías ver

`Amazon Linux 2023`, el usuario `root` y `dnf` (el gestor de paquetes de Red Hat).

> **Si dice `Connection closed`:** el servidor SSH tarda hasta un minuto en
> arrancar. Espera y reintenta.
>
> **Si dice `Permission denied (publickey)`:** la llave no coincide. Crea la
> llave **antes** que la instancia: la instancia se queda con la pública que
> existía al crearse.

### Preguntas

9. ¿Qué SO tiene la instancia? ¿Es Ubuntu? ¿Por qué?
10. ¿Por qué entras como `root` y no como un usuario normal?
11. ¿Qué hace `exit`?

---

## Bloque 5 — Crea la base de datos

**Objetivo:** tener un PostgreSQL gestionado (como RDS) sin instalar nada.

### Escribes tú

```bash
aws rds create-db-instance --db-instance-identifier clase-db --engine postgres --db-instance-class db.t3.micro --master-username admin --master-user-password secreto123 --allocated-storage 20
```

```bash
aws rds describe-db-instances --query "DBInstances[].{ID:DBInstanceIdentifier,Estado:DBInstanceStatus,Motor:Engine,Puerto:Endpoint.Port}" --output table
```

### Deberías ver

`available` en estado y el puerto **7001**.

> Si sigue en `creating`, espera unos segundos y repite el `describe`.

### Preguntas

12. ¿Qué diferencia hay entre una base de datos "gestionada" (RDS) y montarla tú
    en la instancia?
13. ¿Dónde está el respaldo automático en un RDS real?

---

## Bloque 6 — Conéctate con psql

**Objetivo:** hablar con la base de datos desde tu equipo.

`psql` es el cliente oficial de PostgreSQL.

### Escribes tú

```bash
PGPASSWORD=secreto123 psql -h localhost -p 7001 -U admin -d postgres -c "SELECT version();"
```

### Deberías ver

`PostgreSQL 16.3 ...` en una fila.

> **Si se queda colgado o te pide más:** es el paginador. Añade `-P pager=off`
> o escribe `\pset pager off` dentro de psql.
>
> **Si el prompt es `postgres-#`:** te falta cerrar la sentencia con `;`.
> Pulsa `Ctrl+C` y vuelve a empezar.

### Preguntas

14. ¿Qué significan `-h`, `-p`, `-U` y `-d`?
15. ¿Por qué la contraseña va en la variable `PGPASSWORD` y no en el comando?

---

## Bloque 7 — Tu primera tabla

**Objetivo:** crear una tabla, meter datos y consultarlos.

Entra en la consola interactiva:

```bash
PGPASSWORD=secreto123 psql -h localhost -p 7001 -U admin -d postgres
```

Dentro, desactiva el paginador:

```sql
\pset pager off
```

Crea la tabla:

```sql
CREATE TABLE alumnos (id SERIAL PRIMARY KEY, nombre VARCHAR(50), nota NUMERIC(4,2));
```

Inserta tres filas:

```sql
INSERT INTO alumnos (nombre, nota) VALUES ('Ana', 8.5), ('Luis', 6.0), ('Marta', 9.25);
```

Consúltalas:

```sql
SELECT * FROM alumnos;
```

Filtra:

```sql
SELECT nombre, nota FROM alumnos WHERE nota >= 8 ORDER BY nota DESC;
```

Actualiza:

```sql
UPDATE alumnos SET nota = 7.0 WHERE nombre = 'Luis';
```

Comprueba el cambio:

```sql
SELECT * FROM alumnos;
```

Borra una fila:

```sql
DELETE FROM alumnos WHERE nombre = 'Luis';
```

Cuenta cuántas quedan:

```sql
SELECT COUNT(*) FROM alumnos;
```

Y sal:

```sql
\q
```

### Deberías ver

Al principio tres filas; después de borrar, dos.

### Preguntas

16. ¿Qué hace `SERIAL` en la columna `id`?
17. ¿Qué diferencia hay entre `DELETE` y `DROP TABLE`?
18. ¿Por qué `UPDATE` sin `WHERE` es peligroso?

---

## Bloque 8 — Autoevalúa y entrega

**Objetivo:** saber tu nota antes de que la vea el profesor.

### Escribes tú

```bash
./practica/verificar.sh
```

Verás una tabla con cada criterio, sus puntos y una nota final sobre 100.

Si algo falla, el mensaje te dice qué bloque repasar. Cuando esté todo:

```bash
./practica/verificar.sh --guardar
```

Eso genera tu entrega en `practica/entregas/<tu-usuario>-<fecha>/` con:

- `entrega.json` — la nota y el detalle de cada criterio
- `salida.txt` — la salida completa del verificador
- `informe.md` — la plantilla con las preguntas (rellénala)

### Rúbrica (100 puntos)

| Criterio | Puntos | Qué se comprueba |
|---|---:|---|
| Entorno | 10 | Docker responde |
| Floci | 10 | El emulador está sano |
| Credenciales | 5 | `sts` devuelve `000000000000` |
| Imagen de EC2 | 5 | La AMI lleva sshd y el arreglo de PAM |
| Llave | 5 | `.pem` existe y tiene permisos 400 |
| Instancia | 10 | EC2 en `running` |
| **SSH** | 15 | Entras y ves `Amazon Linux` |
| Base de datos | 10 | RDS en `available` |
| `psql` | 10 | Conectas y responde |
| **Tabla** | 20 | Existe `alumnos` con al menos 3 filas |

---

## Bloque 9 — Limpia tu equipo

**Objetivo:** no dejar contenedores ni recursos colgando.

Borra los recursos de AWS:

```bash
aws ec2 terminate-instances --instance-ids $(aws ec2 describe-instances --query "Reservations[].Instances[].InstanceId" --output text)
```

```bash
aws rds delete-db-instance --db-instance-identifier clase-db --skip-final-snapshot
```

```bash
docker rm -f floci
```

```bash
docker ps -a
```

### Preguntas

19. ¿Qué pasaría si no borras la instancia? (Piensa en el coste en AWS real.)
20. ¿Por qué `docker rm -f` y no `docker stop`?

---

## Informe

Copia `entregas/<tu-usuario>-<fecha>/informe.md` y responde ahí las 20 preguntas.
Puedes acompañarlas de capturas de pantalla de los bloques 4 y 7.

Entrega el directorio completo `practica/entregas/<tu-usuario>-<fecha>/`.
