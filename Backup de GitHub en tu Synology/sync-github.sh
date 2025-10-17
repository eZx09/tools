#!/bin/sh
# 🔄 sync-github.sh — Sincroniza repos de GitHub (públicos/privados) en un NAS
# - Prefiere SSH; usa token solo para listar/HTTPS fallback
# - Mueve entre pub↔priv si cambia visibilidad
# - Detecta renombres (por ID) y mueve carpeta (.repo_id)
# - Prune de repos eliminados
# - Telegram con emojis, timestamp y extracto de log si hay incidencias
# - Snapshots .tar.gz opcionales

set -eu

# ========= VARIABLES DE ENTORNO (requeridas/opcionales) =========
: "${GITHUB_USER:?Falta GITHUB_USER}"        # Usuario de GitHub (no email)
: "${TELEGRAM_TOKEN:?Falta TELEGRAM_TOKEN}"  # Bot token de Telegram
: "${TELEGRAM_CHAT_ID:?Falta TELEGRAM_CHAT_ID}"  # chat_id destino

USE_SSH="${USE_SSH:-1}"                 # 1=SSH (recomendado), 0=HTTPS con token
GITHUB_TOKEN="${GITHUB_TOKEN:-}"        # para listar privados y clonar por HTTPS si hiciera falta
PRUNE_LOCAL="${PRUNE_LOCAL:-1}"         # 1=eliminar repos locales que ya no existen en GitHub

# Rutas (customizables por .env) - valores genéricos para Synology
BASE="${BASE:-/volume1/git-mirrors}"                       # raíz de los repos locales
LOG_DIR="${LOG_DIR:-/volume1/scripts/logs/sync_github}"    # carpeta de logs

# Snapshots (opcionales)
SNAPSHOT_ENABLE="${SNAPSHOT_ENABLE:-0}"                    # 1=activar snapshots
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/volume1/backups/github}"    # carpeta para .tar.gz
SNAPSHOT_RETENTION_DAYS="${SNAPSHOT_RETENTION_DAYS:-7}"
TAIL_N="${TAIL_N:-10}"                                     # líneas de log en incidencias
# ================================================================

# Normaliza por si .env tuvo CRLF
GITHUB_USER=$(printf '%s' "$GITHUB_USER" | tr -d '\r')
TELEGRAM_TOKEN=$(printf '%s' "$TELEGRAM_TOKEN" | tr -d '\r')
TELEGRAM_CHAT_ID=$(printf '%s' "$TELEGRAM_CHAT_ID" | tr -d '\r')
USE_SSH=$(printf '%s' "$USE_SSH" | tr -d '\r')
GITHUB_TOKEN=$(printf '%s' "$GITHUB_TOKEN" | tr -d '\r')
PRUNE_LOCAL=$(printf '%s' "$PRUNE_LOCAL" | tr -d '\r')
BASE=$(printf '%s' "$BASE" | tr -d '\r')
LOG_DIR=$(printf '%s' "$LOG_DIR" | tr -d '\r')
SNAPSHOT_ENABLE=$(printf '%s' "$SNAPSHOT_ENABLE" | tr -d '\r')
SNAPSHOT_DIR=$(printf '%s' "$SNAPSHOT_DIR" | tr -d '\r')
SNAPSHOT_RETENTION_DAYS=$(printf '%s' "$SNAPSHOT_RETENTION_DAYS" | tr -d '\r')
TAIL_N=$(printf '%s' "$TAIL_N" | tr -d '\r')

PUB="${BASE}/pub"
PRIV="${BASE}/priv"
LOG_FILE="${LOG_DIR}/sync-$(date +%F).log"

mkdir -p "$PUB" "$PRIV" "$LOG_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

need() { command -v "$1" >/dev/null 2>&1 || { log "❌ Falta $1"; exit 1; }; }
need git; need curl; need jq

# SSH: evita prompt de host key (entornos sin ssh-keyscan)
if [ "$USE_SSH" = "1" ]; then
  export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new'
fi

# Emoji por visibilidad
icon_for_priv() { [ "$1" = "true" ] && printf "🔒" || printf "🌐"; }

log "==== Iniciando sync-github en $BASE (usuario: $GITHUB_USER) ===="

# ---- Descarga lista de repos (paginado). TOKEN => incluye privados ----
PAGE=1
ALL="[]"
while :; do
  if [ -n "$GITHUB_TOKEN" ]; then
    URL="https://api.github.com/user/repos?per_page=100&page=$PAGE&affiliation=owner&sort=full_name"
    RESP="$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" "$URL")"
  else
    URL="https://api.github.com/users/${GITHUB_USER}/repos?per_page=100&page=$PAGE&type=owner&sort=full_name"
    RESP="$(curl -sS "$URL")"
  fi
  COUNT=$(echo "$RESP" | jq 'length')
  ALL=$(jq -s 'add' <<EOF
$ALL
$RESP
EOF
)
  [ "$COUNT" -lt 100 ] && break
  PAGE=$((PAGE+1))
done

# ---- Contadores y listas ----
CLONADOS=0; ACTUALIZADOS=0; MOVIDOS=0; PRUNED=0; RENOMBRADOS=0
CLONADOS_LIST=""; ACTUALIZADOS_LIST=""; MOVIDOS_LIST=""; PRUNED_LIST=""; RENOMBRADOS_LIST=""

SEEN_FILE="$(mktemp)"
TMP_LIST="$(mktemp)"

# Campos: id, name, private, ssh_url, https_url, default_branch
echo "$ALL" | jq -rc '.[] | [.id, .name, .private, .ssh_url, .clone_url, .default_branch] | @tsv' > "$TMP_LIST"

# ---- Procesado (sin subshell) ----
while IFS="$(printf '\t')" read -r REPO_ID NAME PRIVATE SSHURL HTTPSURL BRANCH; do
  PRIVATE=$(printf '%s' "$PRIVATE" | tr -d '\r')
  SSHURL=$(printf '%s' "$SSHURL" | tr -d '\r')
  HTTPSURL=$(printf '%s' "$HTTPSURL" | tr -d '\r')
  BRANCH=$(printf '%s' "$BRANCH" | tr -d '\r')

  # Destino por visibilidad
  if [ "$PRIVATE" = "true" ]; then
    VISDIR="$PRIV"; OTHER="$PUB"
  else
    VISDIR="$PUB";  OTHER="$PRIV"
  fi
  DEST="${VISDIR}/${NAME}"

  # Renombrado por ID (mueve carpeta al nuevo nombre y/o pub↔priv)
  EXISTING_PATH="$(grep -Rsl --include='.repo_id' -e "^${REPO_ID}$" "$PUB" "$PRIV" 2>/dev/null | sed 's|/.repo_id$||' | head -n1 || true)"
  if [ -n "$EXISTING_PATH" ] && [ "$EXISTING_PATH" != "$DEST" ]; then
    mkdir -p "$VISDIR"
    mv "$EXISTING_PATH" "$DEST"
    RENOMBRADOS=$((RENOMBRADOS+1))
    ICON="$(icon_for_priv "$PRIVATE")"
    RENOMBRADOS_LIST="${RENOMBRADOS_LIST}\n  - ${ICON} ${NAME}"
  fi

  # Cambio de visibilidad con mismo nombre (pub↔priv)
  if [ -d "${OTHER}/${NAME}/.git" ] && [ ! -d "$DEST/.git" ]; then
    mv "${OTHER}/${NAME}" "$DEST"
    MOVIDOS=$((MOVIDOS+1))
    ICON="$(icon_for_priv "$PRIVATE")"
    MOVIDOS_LIST="${MOVIDOS_LIST}\n  - ${ICON} ${NAME}"
  fi

  if [ -d "$DEST/.git" ]; then
    git -C "$DEST" fetch --all --prune >>"$LOG_FILE" 2>&1 || true
    if git -C "$DEST" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
      git -C "$DEST" checkout "${BRANCH}" >>"$LOG_FILE" 2>&1 || true
    fi
    if git -C "$DEST" pull --ff-only >>"$LOG_FILE" 2>&1; then :; else log "❌ Fallo haciendo pull en $NAME"; fi
    ACTUALIZADOS=$((ACTUALIZADOS+1))
    ICON="$(icon_for_priv "$PRIVATE")"
    ACTUALIZADOS_LIST="${ACTUALIZADOS_LIST}\n  - ${ICON} ${NAME}"
  else
    # Clonado (prefiere SSH si está habilitado y disponible)
    if [ "$USE_SSH" = "1" ] && [ -n "$SSHURL" ]; then CLONE_URL="$SSHURL"; else CLONE_URL="$HTTPSURL"; fi
    mkdir -p "$VISDIR"
    if echo "$CLONE_URL" | grep -q '^git@github.com:'; then
      if git clone "$CLONE_URL" "$DEST" >>"$LOG_FILE" 2>&1; then :; else log "❌ Fallo clonando (SSH) $NAME"; fi
    else
      if [ "$PRIVATE" = "true" ] && [ -z "$GITHUB_TOKEN" ]; then log "❌ Repo privado sin GITHUB_TOKEN (HTTPS): $NAME"; fi
      if [ -n "$GITHUB_TOKEN" ]; then
        STRIPPED=$(echo "$CLONE_URL" | sed 's#https://##')
        if git clone "https://${GITHUB_TOKEN}@${STRIPPED}" "$DEST" >>"$LOG_FILE" 2>&1; then
          git -C "$DEST" remote set-url origin "$HTTPSURL" >>"$LOG_FILE" 2>&1 || true
        else
          log "❌ Fallo clonando (HTTPS+token) $NAME"
        fi
      else
        if git clone "$CLONE_URL" "$DEST" >>"$LOG_FILE" 2>&1; then :; else log "❌ Fallo clonando (HTTPS) $NAME"; fi
      fi
    fi
    git -C "$DEST" checkout "${BRANCH}" >>"$LOG_FILE" 2>&1 || true
    CLONADOS=$((CLONADOS+1))
    ICON="$(icon_for_priv "$PRIVATE")"
    CLONADOS_LIST="${CLONADOS_LIST}\n  - ${ICON} ${NAME}"
  fi

  printf "%s" "$REPO_ID" > "$DEST/.repo_id"
  echo "$DEST" >>"$SEEN_FILE"
done < "$TMP_LIST"
rm -f "$TMP_LIST"

# ---- PRUNE: elimina repos locales que ya no están en GitHub ----
if [ "$PRUNE_LOCAL" = "1" ]; then
  for DIR in "$PUB"/* "$PRIV"/*; do
    [ -d "$DIR/.git" ] || continue
    if ! grep -Fxq "$DIR" "$SEEN_FILE"; then
      BAS=$(basename "$DIR")
      if echo "$DIR" | grep -q "/priv/"; then OLD_ICON="🔒"; else OLD_ICON="🌐"; fi
      rm -rf "$DIR"
      PRUNED=$((PRUNED+1))
      PRUNED_LIST="${PRUNED_LIST}\n  - ${OLD_ICON} ${BAS}"
    fi
  done
fi
rm -f "$SEEN_FILE"

# ---- Snapshot opcional ----
if [ "$SNAPSHOT_ENABLE" = "1" ]; then
  mkdir -p "$SNAPSHOT_DIR"
  SNAP_FILE="${SNAPSHOT_DIR}/github-$(date +%F_%H%M%S).tar.gz"
  tar -czf "$SNAP_FILE" -C "$(dirname "$BASE")" "$(basename "$BASE")" >>"$LOG_FILE" 2>&1 || true
  find "$SNAPSHOT_DIR" -type f -name "github-*.tar.gz" -mtime +"$SNAPSHOT_RETENTION_DAYS" -delete 2>/dev/null || true
fi

# ---- Limpia listas para evitar líneas en blanco extra ----
CLONADOS_LIST=$(printf "%b" "$CLONADOS_LIST" | sed '/^$/d')
ACTUALIZADOS_LIST=$(printf "%b" "$ACTUALIZADOS_LIST" | sed '/^$/d')
MOVIDOS_LIST=$(printf "%b" "$MOVIDOS_LIST" | sed '/^$/d')
PRUNED_LIST=$(printf "%b" "$PRUNED_LIST" | sed '/^$/d')
RENOMBRADOS_LIST=$(printf "%b" "$RENOMBRADOS_LIST" | sed '/^$/d')

# ---- Telegram resumen (Markdown + emojis + hora + estado + log tail si hay incidencias) ----
fmt_section() {
  # $1=emoji $2=título $3=conteo $4=lista (ya con saltos reales)
  if [ "$3" -gt 0 ]; then
    printf "%s *%s:* *%s*\n%s\n" "$1" "$2" "$3" "$4"
  else
    printf "%s *%s:* *0*\n" "$1" "$2"
  fi
}

if grep -q "❌" "$LOG_FILE"; then
  STATUS_EMOJI="⚠️"; STATUS_TEXT="Con incidencias"
  LOG_TAIL=$(tail -n "$TAIL_N" "$LOG_FILE" | sed 's/^/    /')
else
  STATUS_EMOJI="✅"; STATUS_TEXT="OK"
  LOG_TAIL=""
fi

SUMMARY=$(printf "🕒 *%s*\n\n*%s sync-github %s*\n\n%s\n%s\n%s\n%s\n%s\n• *Carpeta:* \`%s\`\n• *Log:* \`%s\`" \
  "$(date '+%Y-%m-%d %H:%M:%S')" \
  "$STATUS_EMOJI" "$STATUS_TEXT" \
  "$(fmt_section '📥' 'Clonados' "$CLONADOS" "$CLONADOS_LIST")" \
  "$(fmt_section '🔄' 'Actualizados' "$ACTUALIZADOS" "$ACTUALIZADOS_LIST")" \
  "$(fmt_section '✏️' 'Renombrados (mantenida carpeta)' "$RENOMBRADOS" "$RENOMBRADOS_LIST")" \
  "$(fmt_section '🔁' 'Movidos pub↔priv' "$MOVIDOS" "$MOVIDOS_LIST")" \
  "$(fmt_section '🗑️' 'Eliminados (prune)' "$PRUNED" "$PRUNED_LIST")" \
  "$BASE" "$LOG_FILE")

if [ -n "$LOG_TAIL" ]; then
  LOG_TAIL_FORMATTED=$(printf "%b" "$LOG_TAIL")
  MSG=$(printf "%s\n\n*🔎 Extracto del log:*\n%s" "$SUMMARY" "$LOG_TAIL_FORMATTED")
else
  MSG="${SUMMARY}"
fi

log "==== Finalizado ===="

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d parse_mode="Markdown" \
  --data-urlencode text="$MSG" >/dev/null || true

exit 0
