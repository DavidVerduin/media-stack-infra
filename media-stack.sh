#!/usr/bin/env bash
#
# media-stack.sh — gestión del media center (Jellyfin + arr-stack + qBittorrent/Gluetun)
#
# Uso:
#   ./media-stack.sh start          Levanta todos los contenedores
#   ./media-stack.sh stop           Para todos los contenedores
#   ./media-stack.sh restart [nom]  Reinicia todo, o solo el contenedor "nom"
#   ./media-stack.sh status         Muestra el estado de cada contenedores
#   ./media-stack.sh logs [nom]     Muestra logs (todos o de un contenedor), Ctrl+C para salir
#   ./media-stack.sh update         Actualiza imágenes y recrea contenedores
#   ./media-stack.sh backup         Copia las carpetas de configuración a un .tar.gz con fecha
#   ./media-stack.sh vpncheck       Comprueba que qBittorrent sale a internet por la IP de la VPN

set -euo pipefail
trap 'echo "ERROR en línea $LINENO: $BASH_COMMAND" >&2' ERR

readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="$DIR/docker-compose.yml"
readonly BACKUP_DIR="${BACKUP_DIR:-$HOME/media-server-backups}"
readonly MEDIA_SERVER_DIR="${MEDIA_SERVER_DIR:-$HOME/media-server}"

cd "$DIR"

COMPOSE_CMD=()

error() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Uso: $0 {start|stop|restart [contenedor]|status|logs [contenedor]|update|backup|vpncheck}

Opciones:
  start                Levanta todos los contenedores
  stop                 Para todos los contenedores
  restart [contenedor] Reinicia el stack o solo un contenedor
  status               Muestra el estado de los contenedores y uso de recursos
  logs [contenedor]    Muestra logs (todos o de un contenedor)
  update               Descarga imágenes nuevas y recrea contenedores
  backup               Copia la configuración de media-server a un .tar.gz
  vpncheck             Comprueba la IP pública desde el contenedor gluetun

Variables de entorno opcionales:
  BACKUP_DIR           Directorio donde guardar backups
  MEDIA_SERVER_DIR     Directorio de configuración a incluir en la copia de seguridad
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || error "Necesitas '$1' instalado y disponible en PATH"
}

require_file_exists() {
  [ -f "$1" ] || error "Falta el archivo: $1"
}

require_dir_exists() {
  [ -d "$1" ] || error "Falta el directorio: $1"
}

detect_compose_cmd() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return
  fi
  error "No se encontró 'docker compose' ni 'docker-compose'. Instala Docker Compose v2 o el binario docker-compose."
}

compose() {
  "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" "$@"
}

container_is_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q '^true$'
}

detect_compose_cmd
require_file_exists "$COMPOSE_FILE"

cmd="${1:-}"

case "$cmd" in
  start)
    echo "Levantando el stack..."
    compose up -d
    compose ps
    ;;

  stop)
    echo "Parando el stack..."
    compose down
    ;;

  restart)
    target="${2:-}"
    if [ -n "$target" ]; then
      echo "Reiniciando solo: $target"
      compose restart "$target"
    else
      echo "Reiniciando todo el stack..."
      compose down
      compose up -d
    fi
    compose ps
    ;;

  status)
    compose ps
    echo
    echo "Uso de recursos:"
    if compose ps -q | grep -q .; then
      docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
    else
      echo "No hay contenedores en ejecución."
    fi
    ;;

  logs)
    target="${2:-}"
    if [ -n "$target" ]; then
      compose logs -f --tail=100 "$target"
    else
      compose logs -f --tail=50
    fi
    ;;

  update)
    echo "Descargando imágenes nuevas..."
    compose pull
    echo "Recreando contenedores con las imágenes nuevas..."
    compose up -d --remove-orphans
    echo "Limpiando imágenes antiguas sin usar..."
    docker image prune -f
    ;;

  backup)
    require_dir_exists "$MEDIA_SERVER_DIR"
    mkdir -p "$BACKUP_DIR"
    stamp="$(date +%Y%m%d-%H%M%S)"
    file="$BACKUP_DIR/media-server-config-$stamp.tar.gz"
    echo "Creando copia de seguridad de configuraciones en $file ..."
    tar -czf "$file" -C "$MEDIA_SERVER_DIR" .
    echo "Hecho: $file"
    ;;

  vpncheck)
    if ! container_is_running gluetun; then
      error "El contenedor 'gluetun' no está en ejecución. Arráncalo antes de ejecutar vpncheck."
    fi

    echo "Última IP pública confirmada por gluetun (debería ser la del proveedor VPN, no tu IP real):"
    ip_line="$(docker logs gluetun 2>&1 | grep "Public IP address" | tail -1)"
    if [ -n "$ip_line" ]; then
      echo "$ip_line"
    else
      echo "No se encontró aún la línea de IP pública en los logs de gluetun." >&2
      echo "Espera unos segundos tras arrancar el contenedor y vuelve a intentarlo." >&2
      exit 1
    fi
    ;;

  -*|--*|"")
    usage
    exit 1
    ;;

  *)
    usage
    exit 1
    ;;
esac

