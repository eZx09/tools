# 🔄 Backup de GitHub en tu Synology

Sincroniza automáticamente todos tus repositorios de GitHub (públicos y privados) en tu NAS Synology:

- ✅ Clona y actualiza repos (SSH por defecto)
- ✅ Separa públicos y privados en `pub/` y `priv/`
- ✅ Detecta renombres por ID y mueve carpetas
- ✅ Limpia repos eliminados (prune)
- ✅ Notifica por Telegram con detalles y extracto del log
- ✅ (Opcional) Snapshots `.tar.gz` con retención

---

## Requisitos

En tu NAS deben estar disponibles:

```bash
git --version
jq --version
curl --version
```

> En Synology puedes instalarlos desde **Centro de paquetes** o vía `synopkg`.

---

## Estructura de carpetas (por defecto)

```
/volume1/
 ├─ git-mirrors/
 │   ├─ pub/      # repos públicos
 │   └─ priv/     # repos privados
 └─ scripts/
     └─ logs/
         └─ sync_github/
```

Puedes cambiar estas rutas en el `.env`.

---

## Configuración

1. **Clave SSH (recomendada)**  
   Genera una clave en el usuario que ejecutará el script:
   ```bash
   ssh-keygen -t ed25519 -C "synology"
   cat ~/.ssh/id_ed25519.pub
   ```
   Añádela en GitHub → *Settings → SSH and GPG keys*.

2. **Token GitHub (opcional)**  
   Solo si prefieres HTTPS o necesitas listar privados sin SSH:
   - *Settings → Developer settings → Personal access tokens (classic)*
   - Scopes: `repo` (y `read:org` si usas organizaciones)

3. **Bot de Telegram**  
   - Crea un bot con [@BotFather](https://t.me/BotFather) → copia `TELEGRAM_TOKEN`
   - Obtén tu `chat_id` (por ejemplo con `getUpdates`)

4. **Descarga y prepara archivos**
   ```bash
   # coloca el script y el env en, por ejemplo:
   /volume1/scripts/sync-github.sh
   /volume1/scripts/sync-github.env

   chmod +x /volume1/scripts/sync-github.sh
   mkdir -p /volume1/git-mirrors /volume1/scripts/logs/sync_github
   ```

5. **Edita `.env`**
   ```bash
   cp sync-github.env.example sync-github.env
   # abre y completa tus valores
   ```

---

## Ejecución manual

```bash
set -a
. /volume1/scripts/sync-github.env
set +a
/volume1/scripts/sync-github.sh
```

> Si editas en Windows con VS Code, asegúrate de guardar los `.sh` y `.env` con **LF** (barra inferior → “LF”).

---

## Programar en DSM (Task Scheduler)

1. **Panel de control → Programador de tareas → Crear → Script definido por el usuario**
2. **Usuario:** el que tenga la clave SSH y permisos de escritura en las carpetas
3. **Script:**
   ```bash
   set -a
   . /volume1/scripts/sync-github.env
   set +a
   /volume1/scripts/sync-github.sh
   ```
4. Programa la hora (ej. diario 03:00)

---

## Notificaciones

Mensaje típico de Telegram:

```
🕒 2025-10-17 03:10:22

✅ sync-github OK

📥 Clonados: 1
  - 🔒 repo-privado
🔄 Actualizados: 2
  - 🌐 repo-publico
  - 🔒 repo-privado
✏️ Renombrados (mantenida carpeta): 0
🔁 Movidos pub↔priv: 0
🗑️ Eliminados (prune): 0
• Carpeta: /volume1/git-mirrors
• Log: /volume1/scripts/logs/sync_github/sync-2025-10-17.log
```

Si hay incidencias, verás `⚠️` y un *extracto del log*.

---

## Troubleshooting

- **Se ven `\\n` en Telegram** → usa la última versión del script (bloque final con `printf "%b"`).
- **“Permission denied (publickey)”** → asegúrate de que la **clave pública** está en tu GitHub y los permisos de `~/.ssh`:
  ```bash
  chmod 700 ~/.ssh
  chmod 600 ~/.ssh/id_ed25519
  chmod 644 ~/.ssh/id_ed25519.pub ~/.ssh/known_hosts
  ```
- **CRLF**: si el `.env` o `.sh` vienen de Windows:
  ```bash
  sed -i 's/\r$//' /ruta/al/archivo
  ```

---

## Variables principales (prioridad)

- El script toma valores del **entorno** o del **.env** que exportas con `set -a`.
- Si una variable no está definida, usa su **valor por defecto** (ej. `BASE`, `LOG_DIR`, etc.).
- Variables críticas (`GITHUB_USER`, `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`) son **obligatorias**.

---

## Licencia

MIT
