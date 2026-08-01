# Tutorial completo: Media Center casero con Docker, automatización y acceso remoto

Guía de referencia de todo el proyecto: desde instalar Ubuntu Server en el portátil hasta tener Jellyfin, Sonarr/Radarr, un panel de control con CI/CD propio, y acceso remoto vía Tailscale.

Cada sección incluye los comandos exactos usados y, cuando aplica, una caja **"⚠️ Si te encuentras con este error"** con el problema real que apareció durante el montaje y su solución.

---

## Índice

0. [Requisitos previos](#0-requisitos-previos)
1. [Instalación de Ubuntu Server](#1-instalación-de-ubuntu-server)
2. [Configuración inicial del sistema](#2-configuración-inicial-del-sistema)
3. [Docker y el stack base](#3-docker-y-el-stack-base)
4. [VPN (gluetun) y qBittorrent](#4-vpn-gluetun-y-qbittorrent)
5. [Prowlarr, indexadores y Cloudflare](#5-prowlarr-indexadores-y-cloudflare)
6. [Sonarr y Radarr](#6-sonarr-y-radarr)
7. [Jellyfin](#7-jellyfin)
8. [Jellyseerr](#8-jellyseerr)
9. [Bazarr (subtítulos)](#9-bazarr-subtítulos)
10. [Perfiles de calidad e idioma](#10-perfiles-de-calidad-e-idioma)
11. [Panel de control web: repos, CI/CD y GHCR](#11-panel-de-control-web-repos-cicd-y-ghcr)
12. [Comprobación de actualizaciones del panel](#12-comprobación-de-actualizaciones-del-panel)
13. [Acceso remoto con Tailscale](#13-acceso-remoto-con-tailscale)
14. [Apéndice: mapa rápido de todos los errores](#14-apéndice-mapa-rápido-de-todos-los-errores)

---

## 0. Requisitos previos

- Un portátil viejo que puedas dedicar por completo a esto (se borra Windows).
- Un pendrive USB (4GB+).
- Otro ordenador para crear el USB de instalación.
- Una cuenta de VPN que soporte WireGuard (aquí: ProtonVPN).
- Una cuenta de GitHub (para los repos y CI/CD, más adelante).

---

## 1. Instalación de Ubuntu Server

### Backup primero
Copia cualquier archivo personal del portátil a otro sitio. Este proceso borra Windows por completo.

### Crear el USB de instalación
1. Descarga Ubuntu Server LTS desde ubuntu.com/download/server (.iso)
2. Descarga e instala Rufus (rufus.ie)
3. En Rufus: selecciona el USB, selecciona el .iso, y si falla con la configuración por defecto usa Partition scheme=GPT, Target system=UEFI

### Arrancar desde el USB
1. Conecta el USB, reinicia el portátil
2. Pulsa la tecla de arranque repetidamente (en este portátil: **F2**)
3. Si no arranca desde USB: entra en BIOS/UEFI, desactiva Secure Boot (puede pedir fijar una contraseña de supervisor antes), y usa **F6** para subir el USB al principio de la prioridad de arranque

### El instalador
1. Idioma → Español o el que prefieras
2. Teclado → el que corresponda físicamente
3. Red → debería autodetectar por DHCP, está bien por ahora
4. **Storage configuration** (la parte importante):
   - Elige **Custom storage layout**, no la opción guiada
   - SSD → partición de arranque + raíz (/), todo el disco para el sistema
   - HDD/disco de almacenamiento → formatéalo como ext4, punto de montaje `/mnt/storage`
5. Crea tu usuario y contraseña — los usarás para SSH
6. **Instala OpenSSH server** cuando te lo pregunte
7. Omite los "featured server snaps" (Docker se instala luego a mano)
8. Termina, quita el USB, reinicia

### Primer login
```bash
ip a   # para ver tu IP asignada
```
Desde tu PC principal:
```bash
ssh tu_usuario@192.168.1.XX
```

---

## 2. Configuración inicial del sistema

```bash
sudo apt update && sudo apt upgrade -y
```

### IP estática
```bash
ip a   # confirma el nombre de tu interfaz, ej. eth0
sudo nano /etc/netplan/00-installer-config.yaml
```
```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: no
      addresses: [192.168.1.50/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
```
```bash
sudo netplan apply
```

### Que el servidor nunca se duerma
```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

### Firewall básico
```bash
sudo ufw allow OpenSSH
sudo ufw allow 8096   # Jellyfin
sudo ufw enable
```

> **Nota para más adelante**: Docker gestiona sus propias reglas de `iptables` para los puertos que publica en `docker-compose.yml`, y estas reglas **evitan por completo el filtrado de `ufw`**. Es decir: aunque aquí solo abramos 8096 explícitamente, cualquier puerto publicado por un contenedor Docker (Sonarr, Radarr, Jellyseerr, etc.) será alcanzable igualmente desde la LAN — es un comportamiento conocido de Docker, no un fallo de seguridad tuyo.

### Docker
```bash
sudo apt install docker.io docker-compose -y
sudo usermod -aG docker $USER
```
Cierra sesión y vuelve a entrar (o reinicia) para que el cambio de grupo tenga efecto.

---

## 3. Docker y el stack base

Estructura de carpetas:
```bash
mkdir -p /mnt/storage/{movies,tv,downloads}
mkdir -p ~/media-server/{jellyfin,qbittorrent,prowlarr,sonarr,radarr,bazarr,jellyseerr}
cd ~/media-server
```

`docker-compose.yml` completo del stack (sin el `version:` — es un atributo obsoleto):

```yaml
services:
  gluetun:
    image: qmcgaw/gluetun
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    environment:
      - VPN_SERVICE_PROVIDER=protonvpn
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=TU_CLAVE_PRIVADA_AQUI
      - SERVER_COUNTRIES=France
      - HTTPPROXY=on
      - HTTPPROXY_USER=prowlarr
      - HTTPPROXY_PASSWORD=CAMBIA_ESTA_CONTRASEÑA
    ports:
      - 8080:8080
      - 8888:8888
      - 6881:6881
      - 6881:6881/udp
    restart: unless-stopped

  qbittorrent:
    image: linuxserver/qbittorrent
    container_name: qbittorrent
    network_mode: "service:gluetun"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    volumes:
      - ~/media-server/qbittorrent:/config
      - /mnt/storage/downloads:/downloads
    depends_on:
      - gluetun
    restart: unless-stopped

  jellyfin:
    image: jellyfin/jellyfin
    container_name: jellyfin
    ports:
      - 8096:8096
    volumes:
      - ~/media-server/jellyfin:/config
      - /mnt/storage:/media
    restart: unless-stopped

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - TZ=Europe/Madrid
      - PROXY_URL=http://gluetun:8888
      - PROXY_USERNAME=prowlarr
      - PROXY_PASSWORD=CAMBIA_ESTA_CONTRASEÑA
    ports:
      - 8191:8191
    restart: unless-stopped

  prowlarr:
    image: linuxserver/prowlarr
    container_name: prowlarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    volumes:
      - ~/media-server/prowlarr:/config
    ports:
      - 9696:9696
    restart: unless-stopped

  sonarr:
    image: linuxserver/sonarr
    container_name: sonarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    volumes:
      - ~/media-server/sonarr:/config
      - /mnt/storage:/media
    ports:
      - 8989:8989
    restart: unless-stopped

  radarr:
    image: linuxserver/radarr
    container_name: radarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    volumes:
      - ~/media-server/radarr:/config
      - /mnt/storage:/media
    ports:
      - 7878:7878
    restart: unless-stopped

  bazarr:
    image: linuxserver/bazarr
    container_name: bazarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    volumes:
      - ~/media-server/bazarr:/config
      - /mnt/storage:/media
    ports:
      - 6767:6767
    restart: unless-stopped

  jellyseerr:
    image: fallenbagel/jellyseerr
    container_name: jellyseerr
    environment:
      - TZ=Europe/Madrid
    volumes:
      - ~/media-server/jellyseerr:/app/config
    ports:
      - 5055:5055
    restart: unless-stopped

  watchtower:
    image: nickfedor/watchtower
    container_name: watchtower
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      - WATCHTOWER_CLEANUP=true
    restart: unless-stopped
```

```bash
docker compose up -d
```

> **⚠️ Si ves el warning**: `the attribute 'version' is obsolete` — es solo un aviso, no un error. Bórralo del archivo cuando quieras, no afecta al funcionamiento.

> **⚠️ Si usaste `containrrr/watchtower` y se queda reiniciando en bucle**, con un log como `client version 1.25 is too old. Minimum supported API version is 1.44` → ese repositorio está archivado (dejó de actualizarse) y su cliente Docker interno es demasiado antiguo para Docker Engine moderno. Solución: usa `nickfedor/watchtower` (el fork mantenido), como ya está en el compose de arriba.

---

## 4. VPN (gluetun) y qBittorrent

### Por qué hace falta
Muchos ISPs (incluido en España) bloquean el acceso directo a webs de indexadores de torrents por orden judicial. La VPN evita esto — pero solo para el tráfico que pasa explícitamente por gluetun.

### Verificar que la VPN funciona
```bash
docker logs gluetun --tail 30 | grep "Public IP address"
```
Debería mostrar una IP y ubicación del país de tu VPN (ej. Francia), no tu IP real.

> **⚠️ Si tu script de comprobación de IP falla con "wget: command not found"** → las imágenes modernas de gluetun no incluyen `wget` ni `curl`. En vez de intentar ejecutar herramientas dentro del contenedor, lee directamente su propio log (como el comando de arriba) — es más fiable.

> **⚠️ Si cambias variables de entorno en `gluetun` (como `HTTPPROXY`) y no parecen aplicarse** →
> 1. Confirma que el archivo realmente se guardó: `grep -n "HTTPPROXY" docker-compose.yml`
> 2. Si está en el archivo pero sigue sin aplicarse, fuerza una recreación completa (no solo un restart):
>    ```bash
>    docker compose up -d --force-recreate gluetun
>    ```

> **⚠️ Si tras recrear `gluetun`, qBittorrent deja de responder en el puerto 8080** → esto pasa porque `qbittorrent` usa `network_mode: "service:gluetun"`, y al recrear gluetun se genera un contenedor con un ID nuevo — qbittorrent queda "huérfano", apuntando al contenedor viejo que ya no existe. Solución: recrea también qbittorrent después de gluetun:
> ```bash
> docker compose up -d --force-recreate qbittorrent
> ```

### Contraseña del WebUI de qBittorrent
La primera vez, genera una contraseña temporal aleatoria:
```bash
docker logs qbittorrent 2>&1 | grep -i "temporary password"
```
Entra en `http://IP:8080`, cambia la contraseña en Tools → Options → Web UI.

---

## 5. Prowlarr, indexadores y Cloudflare

### Añadir indexadores
Prowlarr → Add Indexer → busca por nombre (1337x, EliteTorrent, YTS, EZTV, Nyaa, etc.)

> **⚠️ Error: "Unable to connect to indexer... Connection refused" en un indexador específico** (ej. `elitetorrent.wf`) → probablemente tu ISP bloquea ese dominio directamente. Solución: enruta ese indexador específico a través del proxy HTTP de gluetun.
>
> 1. Prowlarr → Settings → Indexers → **Indexer Proxies** → añade uno tipo **HTTP**, host `gluetun`, puerto `8888`, usuario/contraseña los de `HTTPPROXY_USER`/`HTTPPROXY_PASSWORD`
> 2. **Importante**: el enlace entre indexador y proxy es por **Tags**, no por un desplegable de "Proxy" directo. Ponle el mismo tag (ej. `vpn`) tanto al proxy como al indexador afectado.

> **⚠️ Error: "Unable to access 1337x.to, blocked by Cloudflare Protection"** → necesitas FlareSolverr (ya incluido en el compose de la sección 3). Configúralo:
> 1. Prowlarr → Indexer Proxies → añade uno tipo **FlareSolverr**, host `http://flaresolverr:8191`, tag `cloudflare`
> 2. Añade el mismo tag `cloudflare` al indexador afectado (1337x, etc.)

> **⚠️ Error en el log de FlareSolverr: `net::ERR_CONNECTION_REFUSED`** al intentar resolver el desafío → FlareSolverr en sí mismo no está pasando por la VPN, así que sufre el mismo bloqueo del ISP que el indexador. Solución: dale también acceso al proxy de gluetun (variables `PROXY_URL`, `PROXY_USERNAME`, `PROXY_PASSWORD` ya incluidas en el compose de la sección 3).

> **⚠️ Error: "Unable to connect to proxy... Connection refused (localhost:8191)"** → el campo Host del proxy se guardó como `localhost` en vez de `http://flaresolverr:8191`. Dentro de un contenedor, "localhost" significa "yo mismo", nunca otro contenedor — corrige el campo Host.

> **⚠️ Error 500 al usar el proxy FlareSolverr aunque esté bien configurado** → revisa `docker logs flaresolverr` para ver la causa real (a veces es exactamente el problema del punto anterior, ERR_CONNECTION_REFUSED, resuelto con el `PROXY_URL`).

---

## 6. Sonarr y Radarr

### Conectar Prowlarr con Sonarr/Radarr
Prowlarr → Settings → Apps → Add Application:
- Sonarr: Server `http://sonarr:8989`, API Key desde Sonarr → Settings → General → Security
- Radarr: Server `http://radarr:7878`, API Key desde Radarr → Settings → General → Security

> **⚠️ Si te preguntan por la "Prowlarr Server URL" al configurar esto y usas `http://localhost:9696`** → no funciona, mismo motivo de siempre: usa el nombre del contenedor, `http://prowlarr:9696`.

### Añadir root folders
Settings → Media Management → Root Folders → `/media/tv` (Sonarr) o `/media/movies` (Radarr)

> **⚠️ Error: "Folder '/media/tv/' is not writable by user 'abc'"** → el contenedor corre internamente como UID/GID 1000 (`abc`), pero la carpeta real en el host no tiene esos permisos. Solución:
> ```bash
> sudo chown -R 1000:1000 /mnt/storage
> sudo chmod -R 775 /mnt/storage
> ```

### Configurar qBittorrent como cliente de descarga
Settings → Download Clients → qBittorrent:
- Host: `gluetun` (no `qbittorrent`, no `localhost` — comparte la red de gluetun)
- Puerto: `8080`

> **⚠️ Descarga completa en qBittorrent, pero Sonarr/Radarr la muestra como "waiting for import" sin error** → problema de **mapeo de rutas**. qBittorrent ve los archivos en `/downloads/...`, pero Sonarr/Radarr solo tiene montado `/media`, así que esa ruta no existe para ellos. Solución: **Remote Path Mappings**:
> 1. Settings → Download Clients → Remote Path Mappings → añade:
>    - Host: `gluetun`
>    - Remote Path: `/downloads/`
>    - Local Path: `/media/downloads/`
> 2. Repite en Sonarr y en Radarr.

> **⚠️ La importación funciona, pero el archivo termina en `/media/downloads/Nombre.../...` en vez de `/media/movies/...`** → el Root Folder configurado para esa película específica apunta mal. Edita la película → cambia su Root Folder Path a `/media/movies` → debería ofrecer mover los archivos automáticamente.

> **⚠️ Una serie de TV termina en la carpeta de películas** → probablemente se solicitó/añadió como película por error (en Jellyseerr, o directamente en Radarr) en vez de como serie en Sonarr. Elimina la entrada de Radarr (conservando los archivos), añádela correctamente en Sonarr, y mueve los archivos a `/mnt/storage/tv/`.

---

## 7. Jellyfin

### Asistente inicial
`http://IP:8096` → crea usuario admin → añade dos bibliotecas:
- **Movies**, carpeta `/media/movies`
- **TV Shows**, carpeta `/media/tv`

> **⚠️ Los archivos están en el disco pero no aparecen en Jellyfin tras un rescan normal** → prueba primero un rescan manual (Dashboard → Libraries → ⋮ → Scan Library Files). Si sigue sin aparecer, comprueba la ruta exacta configurada en la biblioteca (mayúsculas, barra final, etc.) y que Jellyfin realmente puede leer la carpeta:
> ```bash
> docker exec jellyfin ls -la /media/movies
> ```
> Si nada de esto funciona, borra la biblioteca (solo el índice, no los archivos) y vuelve a crearla desde cero apuntando a la ruta exacta.

> **⚠️ Todo el contenido (series incluidas) aparece bajo "Movies"** → la biblioteca de Movies está probablemente apuntando a `/media` en vez de `/media/movies` específicamente, y por eso indexa todo lo que hay debajo, series incluidas.

### App para el televisor
- **Android TV / Google TV**: app oficial "Jellyfin" en la Play Store
- **Samsung Tizen**: oficial en la Tizen Store, solo modelos 2021+
- **LG webOS**: oficial en la LG Content Store
- **Fire TV**: sin tienda oficial, requiere sideload del APK
- **Apple TV**: oficial en la App Store

---

## 8. Jellyseerr

`http://IP:5055` → elige Jellyfin como servidor:
- Jellyfin URL: `http://jellyfin:8096`
- Usuario/contraseña: el admin creado en Jellyfin (no un usuario nuevo)

> **⚠️ "No puedo conectar con Jellyfin desde Jellyseerr"** → confirma que usas `http://jellyfin:8096` (nombre del contenedor), no `localhost` ni una IP externa. Y confirma que ya completaste el asistente de Jellyfin (si aún muestra el asistente de bienvenida al abrirlo, no está listo).

Luego conecta Sonarr y Radarr (Settings → Services), con host `sonarr`/`radarr`, puertos `8989`/`7878`, y sus API keys.

> **⚠️ No aparece ninguna opción de Root Folder al configurar Sonarr/Radarr en Jellyseerr** → dos causas posibles:
> 1. No has pulsado **Test** todavía (el desplegable solo se rellena tras un test exitoso)
> 2. Sonarr/Radarr no tiene ningún Root Folder creado aún — Jellyseerr no puede mostrar lo que no existe, hay que crearlo directamente en Sonarr/Radarr primero (ver sección 6)

---

## 9. Bazarr (subtítulos)

`http://IP:6767`:
1. Settings → Languages → añade tus idiomas, crea un Languages Profile
2. Settings → Sonarr / Settings → Radarr → conecta igual que siempre (`sonarr`/`radarr`, puertos, API keys), y asigna el Language Profile
3. Settings → Subtitles Providers → añade al menos uno (ej. OpenSubtitles.com)

> **⚠️ El botón de buscar subtítulos aparece deshabilitado** → normalmente es una de estas:
> - No hay ningún proveedor de subtítulos configurado todavía
> - El título en cuestión no tiene un Language Profile asignado (revisa/asígnalo desde Sonarr/Radarr directamente)
> - Bazarr cree que ya no falta nada (fuerza un re-scan/sync desde su panel de tareas)

---

## 10. Perfiles de calidad e idioma

> **⚠️ Un anime se descarga con audio en francés en vez de japonés** → en versiones antiguas de Sonarr existían "Language Profiles" separados, pero **Sonarr v4 los eliminó** — ahora el idioma se controla vía **Custom Formats** dentro del Quality Profile:
> 1. Settings → Custom Formats → crea uno con especificación **Language = Japanese**
> 2. Settings → Profiles → Quality Profiles → dale a ese Custom Format una puntuación alta (ej. 100) dentro del perfil que uses para anime
> 3. Para que esto se aplique automáticamente a todo el anime sin tener que hacerlo manualmente cada vez: en Jellyseerr → Settings → Services → tu servidor Sonarr, rellena los campos específicos de **Anime** (Quality Profile, Root Folder) — Jellyseerr detecta automáticamente qué es anime y enruta ahí

### Selección por título (para casos puntuales: película en neerlandés, etc.)
- Al pedir en Jellyseerr, usa la opción **Advanced** (si no aparece, actívala en Settings → Users → tu usuario → permisos) para elegir el Quality Profile de esa petición concreta
- O cambia el Quality Profile directamente en Radarr, en cualquier momento, desde la página de la película

---

## 11. Panel de control web: repos, CI/CD y GHCR

### Arquitectura final
- **`media-stack-infra`**: repo con `docker-compose.yml`, `.env.example`, `README.md` — vive en `~/media-server`
- **`media-stack-control-panel`**: repo independiente con el código del panel (backend Node/Express + frontend estático), con su propio CI/CD que publica en GHCR
- El primero referencia al segundo como **submodule**, solo para poder editarlo cómodamente (VS Code Remote-SSH); el `docker-compose.yml` siempre despliega la **imagen publicada**, nunca construye desde el submodule directamente
- Watchtower recoge automáticamente las nuevas versiones de la imagen

### Backend del panel
Funciones: login por PIN, estado de contenedores + espacio en disco + última IP de la VPN, start/stop/restart, logs, y comprobación/disparo de actualizaciones (sección 12).

### Claves SSH para GitHub — una por repo
```bash
ssh-keygen -t ed25519 -N "" -C "media-server-infra" -f ~/.ssh/id_ed25519_github
ssh-keygen -t ed25519 -N "" -C "media-server-control-panel" -f ~/.ssh/id_ed25519_github_controlpanel
```
```bash
cat >> ~/.ssh/config <<'EOF'
Host github.com-infra
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_github
  IdentitiesOnly yes

Host github.com-controlpanel
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_github_controlpanel
  IdentitiesOnly yes
EOF
```

> **⚠️ `ssh-keygen` imprime "Passphrase is empty" y parece un error** → no lo es, es solo la confirmación normal de que se generó la clave sin contraseña (a propósito, con `-N ""`). Todo el bloque que sigue (fingerprint, randomart) es la salida de éxito estándar.

> **⚠️ "sudo: Authentication failed" repetidamente al escribir la contraseña** → en Linux, la terminal no muestra ningún carácter al escribir la contraseña de sudo (ni asteriscos, ni puntos) — es normal, sigue escribiendo a ciegas y pulsa Enter. Si sigue fallando, prueba `sudo whoami` aislado para confirmar si es un problema real de contraseña.

Añade cada clave pública como **Deploy Key** (con "Allow write access") en su repo correspondiente — GitHub → repo → Settings → Deploy keys.

> **⚠️ Error: "Key is already in use"** al añadir una clave a un segundo repo → GitHub no permite que la misma clave pública sea deploy key de dos repos distintos. Cada repo necesita su propia clave (por eso generamos dos arriba). Si ves esto, revisa si la pegaste sin querer en el repo equivocado antes.

> **⚠️ `git push` da "Permission denied (publickey)"** aunque la clave exista → casi siempre el remoto usa `git@github.com:...` en vez del alias específico. Corrígelo:
> ```bash
> git remote set-url origin git@github.com-controlpanel:TU_USUARIO/media-stack-control-panel.git
> ```
> (o `github.com-infra` según el repo). Verifica con `git remote -v`.

> **⚠️ `git push` da "error: src refspec main does not match any"** → no hay ningún commit todavía. Comprueba con `git status` y `git log --oneline` — si dice "no commits yet", el problema real suele ser que la carpeta está vacía (archivos nunca copiados al servidor) o que `git commit` falló silenciosamente por falta de `git config user.email/user.name`.

### CI/CD (`.github/workflows/build-and-push.yml`)
En cada push a `main`: build de la imagen Docker → push a GHCR (`ghcr.io/tu-usuario/media-stack-control-panel`), usando el `GITHUB_TOKEN` automático (sin secretos extra).

> **⚠️ Error: "invalid tag... repository name must be lowercase"** → GHCR exige nombres en minúsculas, pero `github.repository_owner` puede tener mayúsculas (ej. `DavidVerduin`). Solución: convertir a minúsculas en el propio workflow antes de construir el tag:
> ```yaml
> - name: Convertir owner a minúsculas
>   run: echo "OWNER_LC=$(echo '${{ github.repository_owner }}' | tr '[:upper:]' '[:lower:]')" >> "$GITHUB_ENV"
> ```
> y usar `ghcr.io/${{ env.OWNER_LC }}/...` en los tags.

### En el servidor: usar la imagen publicada
```bash
docker login ghcr.io -u tu_usuario
# password = un Personal Access Token de GitHub con permiso "read:packages"
docker compose pull control-panel
```

> **⚠️ Error: "unauthorized" al hacer `docker compose pull`** → nunca hiciste `docker login ghcr.io` en el servidor (una private image necesita autenticación incluso solo para descargarla, no solo para subirla).

### Submodule
```bash
git submodule add git@github.com-controlpanel:TU_USUARIO/media-stack-control-panel.git control-panel
```

> **⚠️ `git submodule status` da un error tipo "no submodule mapping found... for path 'X-old'"** (por ejemplo, si guardaste una copia de seguridad temporal de la carpeta antes de re-añadir el submodule correctamente) → esa carpeta antigua quedó registrada en el índice de Git como una referencia de submodule aunque ya no exista en disco. Solución:
> ```bash
> git rm --cached nombre-carpeta-vieja
> git commit -m "Elimina referencia residual"
> ```

### `.gitignore` del repo de infraestructura
Las carpetas de configuración real de cada app (con credenciales, bases de datos internas) **nunca deben ir al repo**:
```
.env
bazarr/
jellyfin/
jellyseerr/
prowlarr/
qbittorrent/
radarr/
sonarr/
```

---

## 12. Comprobación de actualizaciones del panel

### Concepto
- **Comprobar**: el backend pregunta a Docker (vía su API de Distribution, sin descargar nada) qué digest tiene la imagen en GHCR ahora mismo, y lo compara con el digest que el contenedor en ejecución está usando.
- **Actualizar**: el propio backend NO se reemplaza a sí mismo (se cortaría a mitad de la operación). En su lugar, le pide a **Watchtower** —que ya está diseñado para esto— que haga su ciclo de actualización ahora mismo, solo para esta imagen, vía su API HTTP.

### Watchtower con API HTTP habilitada
```yaml
environment:
  - WATCHTOWER_HTTP_API_UPDATE=true
  - WATCHTOWER_HTTP_API_PERIODIC_POLLS=true   # mantiene también el chequeo nocturno normal
  - WATCHTOWER_HTTP_API_TOKEN=${WATCHTOWER_HTTP_API_TOKEN}
ports:
  - "8081:8080"   # 8080 ya lo usa gluetun/qbittorrent
```

> **⚠️ Error 401 al comprobar actualizaciones: "unauthorized" contra ghcr.io** → el daemon de Docker no reutiliza automáticamente las credenciales de un `docker login` hecho en el host para peticiones internas a `/distribution/...`; hay que pasarlas explícitamente vía la cabecera `X-Registry-Auth`. Solución: montar el `config.json` que `docker login` ya generó (solo lectura) dentro del contenedor del panel, y que el backend lo lea para construir esa cabecera:
> ```yaml
> volumes:
>   - ~/.docker/config.json:/docker-config/config.json:ro
> environment:
>   - DOCKER_CONFIG_PATH=/docker-config/config.json
> ```

---

## 13. Acceso remoto con Tailscale

### Por qué Tailscale y no exponer puertos públicamente
Tailscale crea una red privada tipo WireGuard entre tus propios dispositivos — sin abrir ningún puerto en tu router, sin exposición pública. Solo dispositivos que tú apruebas explícitamente pueden alcanzar el servidor.

### En el servidor
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```
Abre la URL que imprime, apruébala desde cualquier navegador (no hace falta que sea en el propio servidor).

```bash
tailscale status
tailscale status --json | grep -i dnsname   # para ver el hostname exacto, con MagicDNS
```

> **Nota**: no hace falta tocar `ufw` para esto — los puertos publicados por Docker (Jellyfin, Jellyseerr, panel) ya son alcanzables sobre cualquier interfaz de red del host, Tailscale incluida, por el mismo motivo explicado en la sección 2.

### En el móvil
Instala la app Tailscale (App Store/Play Store), inicia sesión con la misma cuenta.

### En el televisor (Android TV/Google TV)
Play Store del propio televisor → instala "Tailscale" → inicia sesión con la misma cuenta.

### Direcciones a usar, desde cualquier lugar
```
http://tu-servidor.tu-tailnet.ts.net:8096   → Jellyfin
http://tu-servidor.tu-tailnet.ts.net:5055   → Jellyseerr
http://tu-servidor.tu-tailnet.ts.net:4000   → Panel de control
```
En el televisor, añade esta dirección como un segundo servidor en la app de Jellyfin (junto a la dirección local), para poder cambiar entre "en casa" y "fuera de casa".

> **Nota sobre calidad de streaming fuera de casa**: depende de la velocidad de **subida** de tu conexión de casa, no de bajada. 1080p suele ir bien en la mayoría de conexiones domésticas; remuxes 4K pesados pueden forzar una transcodificación si la subida no da abasto — no es un fallo, es una limitación física de tu conexión.

---

## 14. Apéndice: mapa rápido de todos los errores

| Sección | Síntoma | Causa | Solución |
|---|---|---|---|
| 3 | Watchtower reinicia en bucle, log "API version 1.25 too old" | `containrrr/watchtower` archivado, cliente Docker desactualizado | Cambiar a `nickfedor/watchtower` |
| 4 | `vpncheck` no devuelve IP | Sin `wget`/`curl` dentro de gluetun | Leer `docker logs gluetun` en vez de ejecutar herramientas dentro |
| 4 | Variable de entorno de gluetun no se aplica | Falta `--force-recreate`, o el archivo nunca se guardó | `docker compose up -d --force-recreate gluetun`, verificar con `grep` en el archivo |
| 4 | qBittorrent deja de responder tras recrear gluetun | Namespace de red huérfano | `docker compose up -d --force-recreate qbittorrent` |
| 5 | "Connection refused" en un indexador concreto | Bloqueo del ISP | Proxy HTTP de gluetun + mismo tag en proxy e indexador |
| 5 | "Blocked by Cloudflare Protection" | Indexador protegido por Cloudflare | FlareSolverr + mismo tag |
| 5 | FlareSolverr da `ERR_CONNECTION_REFUSED` | FlareSolverr no pasa por la VPN | `PROXY_URL` apuntando a gluetun en FlareSolverr |
| 5 | "Unable to connect to proxy... localhost" | Host del proxy mal puesto como `localhost` | Usar `http://flaresolverr:8191` |
| 6 | "not writable by user 'abc'" | Permisos UID/GID no coinciden | `chown -R 1000:1000 /mnt/storage` |
| 6 | Descarga completa, "waiting for import" sin error | Rutas de descarga y de librería no coinciden entre contenedores | Remote Path Mappings |
| 6 | Película importada en carpeta equivocada | Root Folder mal configurado para ese título | Editar Root Folder Path del título |
| 6 | Serie en la carpeta de películas | Se pidió/añadió como película por error | Eliminar de Radarr, añadir en Sonarr |
| 7 | Archivos en disco pero no en Jellyfin | Ruta de biblioteca incorrecta, o rescan insuficiente | Rescan manual, verificar ruta exacta, o recrear la biblioteca |
| 7 | Todo aparece bajo "Movies" | Biblioteca apunta a `/media` en vez de `/media/movies` | Corregir la ruta de la biblioteca |
| 8 | Jellyseerr no conecta con Jellyfin | Usar `localhost` en vez del nombre del contenedor | `http://jellyfin:8096` |
| 8 | Sin opciones de Root Folder en Jellyseerr | Falta pulsar Test, o Sonarr/Radarr no tiene Root Folder creado | Crear el Root Folder en Sonarr/Radarr primero |
| 10 | Anime se descarga en idioma incorrecto | Sonarr v4 eliminó Language Profiles | Custom Formats + puntuación en Quality Profile |
| 11 | "Key is already in use" en GitHub | Misma clave SSH en dos repos | Una clave por repo, con alias en `~/.ssh/config` |
| 11 | "Permission denied (publickey)" al hacer push | Remoto usa `github.com` plano, no el alias | `git remote set-url` con el alias correcto |
| 11 | "src refspec main does not match any" | No hay commits, o la carpeta está vacía | Confirmar `git log`, copiar los archivos que faltan |
| 11 | "repository name must be lowercase" en GHCR | Usuario de GitHub con mayúsculas | Convertir a minúsculas en el workflow |
| 11 | "unauthorized" al hacer `docker compose pull` | Sin `docker login` en el servidor | `docker login ghcr.io` con un PAT |
| 11 | Error de submodule sobre una carpeta vieja | Referencia residual en el índice de Git | `git rm --cached nombre-carpeta` |
| 12 | 401 al comprobar actualizaciones | El daemon Docker no reutiliza credenciales del host automáticamente | Montar `config.json` + cabecera `X-Registry-Auth` |
| 13 | "sudo: Authentication failed" repetido | La terminal no muestra la contraseña al escribirla (normal) | Escribir a ciegas y pulsar Enter; probar `sudo whoami` si persiste |
