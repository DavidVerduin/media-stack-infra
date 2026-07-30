# media-stack-infra

Orquestación (`docker-compose.yml`) del media center: Jellyfin, Sonarr, Radarr,
Prowlarr, Bazarr, Jellyseerr, qBittorrent+Gluetun (VPN), FlareSolverr,
Watchtower, y el panel de control.

El panel de control (`control-panel/`) es un **submodule** — un repo
independiente (`media-stack-control-panel`) con su propia CI/CD, solo
referenciado aquí para poder editarlo cómodamente (VS Code Remote-SSH, Codex,
etc.). El `docker-compose.yml` NUNCA construye desde esta carpeta: siempre usa
la imagen publicada en GHCR por el CI/CD de ese repo.

## Clonar este repo (primera vez, o en una máquina nueva)

```bash
git clone --recurse-submodules git@github.com:TU_USUARIO/media-stack-infra.git ~/media-server
```

Si ya lo clonaste sin `--recurse-submodules` y `control-panel/` aparece vacío:

```bash
cd ~/media-server
git submodule update --init --recursive
```

## Primer despliegue en el servidor

```bash
cd ~/media-server
cp .env.example .env
nano .env   # pon tu PIN real

# Autenticarse en GHCR para poder tirar de la imagen privada del panel:
docker login ghcr.io -u TU_USUARIO_GITHUB
# (usa un Personal Access Token con permiso "read:packages" como contraseña)

# Sustituye TU_USUARIO_GITHUB en docker-compose.yml por tu usuario real,
# y revisa las variables de gluetun (VPN_SERVICE_PROVIDER, WIREGUARD_PRIVATE_KEY, etc.)

docker compose up -d
```

## Actualizar el panel de control (código)

1. Edita dentro de `control-panel/` normalmente (VS Code Remote-SSH, Codex, lo que uses).
2. `cd control-panel && git add . && git commit -m "..." && git push` — esto
   dispara el CI/CD de ESE repo, que reconstruye y publica en GHCR.
3. Vuelve a `~/media-server` (la raíz) y actualiza el puntero del submodule
   para que quede registrado qué commit exacto de control-panel usa este repo:
   ```bash
   cd ~/media-server
   git add control-panel
   git commit -m "Actualiza puntero de control-panel"
   git push
   ```
   Este paso 3 es solo para mantener el registro correcto — Watchtower ya
   habrá recogido la imagen nueva independientemente de si haces esto o no.

## Forzar una actualización inmediata del panel (sin esperar a Watchtower)

```bash
docker compose pull control-panel
docker compose up -d control-panel
```