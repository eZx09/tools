# DNS Monitor for MikroTik RouterOS

![RouterOS](https://img.shields.io/badge/RouterOS-v7.0+-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Version](https://img.shields.io/badge/version-1.0-orange.svg)

Sistema completo de monitoreo DNS con failover automático y notificaciones Telegram para equipos MikroTik RouterOS v7+.

## 🚀 Características Principales

- Monitoreo continuo de servidor DNS primario (Pi-hole, AdGuard, etc.)
- Failover automático a servidores DNS de respaldo
- Restore automático cuando el DNS primario vuelve a funcionar
- Notificaciones Telegram detalladas de todos los eventos
- 4 modos configurables de manejo DNS del router
- Gestión automática de DHCP con tiempos de lease personalizables
- Detección inteligente con doble verificación anti-falsos positivos
- Estado persistente que sobrevive reinicios del router
- Logging completo para troubleshooting

## 📋 Requisitos

- RouterOS v7.0 o superior
- Acceso a internet para notificaciones Telegram
- Bot de Telegram configurado
- Servidor DNS primario accesible vía ping (Pi-hole, AdGuard, etc.)
- Redes DHCP configuradas con comentarios específicos

## 🔧 Instalación

### 1. Preparación del Bot de Telegram

1. Abrir Telegram y buscar `@BotFather`
2. Crear nuevo bot: `/newbot`
3. Seguir instrucciones y guardar el TOKEN
4. Buscar `@userinfobot` y obtener tu CHAT ID

### 2. Configuración RouterOS

1. Conectar al router vía WinBox, WebFig o SSH
2. Verificar configuración DHCP:
   ```bash
   /ip dhcp-server print
   /ip dhcp-server network print
   ```
3. Asegurar que las DHCP networks tengan comentarios que coincidan con nombres de servidores:
   - DHCP Server: `dhcp-lan` → DHCP Network comment: `dhcp-lan`
   - DHCP Server: `dhcp-iot` → DHCP Network comment: `dhcp-iot`

### 3. Instalación del Script

1. Descargar `dns-monitor.rsc`
2. Editar las variables de configuración:
   ```mikrotik
   :global PIHOLEIP "TU_IP_PIHOLE"
   :global BACKUPDNS "8.8.8.8,1.1.1.1"
   :global TGTOKEN "TU_TOKEN_TELEGRAM"
   :global TGCHAT "TU_CHAT_ID"
   :global ROUTERDNSMODE "balanced"
   ```
3. Copiar y pegar el script completo en la terminal RouterOS
4. El sistema se activará automáticamente cada minuto

## ⚙️ Configuración Avanzada

### Modos de DNS del Router

| Modo          | Descripción                  | Uso Recomendado                            |
|---------------|-----------------------------|--------------------------------------------|
| `none`        | No modifica DNS del router   | Control manual DNS                         |
| `backup-only` | Solo DNS backup siempre      | Router no debe usar Pi-hole                |
| `balanced`    | Pi-hole+backup / solo backup| **Recomendado** - Balance filtrado/dispo   |
| `pihole-only` | Solo Pi-hole / solo backup  | Máximo filtrado                            |

### Configuración DHCP

```mikrotik
# Configuración actual soportada
dhcp-lan:  30m lease normal / 10m failover
dhcp-iot:  2h lease normal  / 10m failover
```

### Añadir Redes DHCP Adicionales

Para añadir más redes (ej: `dhcp-guest`):

1. Crear DHCP server: `dhcp-guest`
2. Crear DHCP network con comment: `dhcp-guest`
3. Modificar script añadiendo en secciones FAILOVER y RESTORE:

   ```mikrotik
   :if ($name = "dhcp-guest") do={
       /ip dhcp-server set $s lease-time=1h
       :foreach n in=[/ip dhcp-server network find where comment="$name"] do={
           /ip dhcp-server network set $n dns-server=$PIHOLEIP
       }
       :set dhcpChanges ($dhcpChanges . "%0Adhcp-guest -> DNS: " . $PIHOLEIP . " | Lease: 1h")
   }
   ```

## 📱 Notificaciones Telegram

### Ejemplo de Mensaje FAILOVER
```
[MikroTik] DNS FAILOVER
Router: MI-ROUTER
Pi-hole: DOWN
Fecha: 24/09/2025 18:30:15
Uptime: 5d12h30m45s

dhcp-lan -> DNS: 8.8.8.8,1.1.1.1 | Lease: 10m
dhcp-iot -> DNS: 8.8.8.8,1.1.1.1 | Lease: 10m

Mode: balanced
Router DNS: 8.8.8.8,1.1.1.1
```

### Ejemplo de Mensaje RESTORE
```
[MikroTik] DNS RESTORE
Router: MI-ROUTER
Pi-hole: UP
Fecha: 24/09/2025 18:35:20
Uptime: 5d12h35m50s

dhcp-lan -> DNS: 192.168.1.100 | Lease: 30m
dhcp-iot -> DNS: 192.168.1.100 | Lease: 2h

Mode: balanced
Router DNS: 192.168.1.100,8.8.8.8,1.1.1.1
```

## 🛠️ Comandos Útiles

```bash
# Test manual del script
/system script run DNS-Monitor-Mikrotik

# Ver logs del sistema
/log print where topics~"script"

# Ver estado del scheduler
/system scheduler print where name="DNS-Monitor"

# Ver estado actual del DNS Monitor
/system script print where name="DNS-Monitor-State"

# Pausar monitoreo
/system scheduler disable DNS-Monitor

# Reanudar monitoreo
/system scheduler enable DNS-Monitor

# Ver configuración DNS actual
/ip dns print

# Ver servidores DHCP
/ip dhcp-server print

# Ver redes DHCP
/ip dhcp-server network print
```

## 🔍 Troubleshooting

### Script no funciona
- Verificar RouterOS v7.0+
- Comprobar permisos del script: `read,write,test,reboot`
- Revisar logs: `/log print where topics~"script"`

### No llegan notificaciones Telegram
- Verificar TOKEN y CHAT ID correctos
- Comprobar conectividad internet del router
- Test manual: `/tool fetch url="https://api.telegram.org/botTU_TOKEN/getMe"`

### Failover no se activa
- Verificar IP Pi-hole accesible: `/ping TU_IP_PIHOLE`
- Comprobar estado: `/system script get [find name="DNS-Monitor-State"] comment`
- Revisar configuración DHCP networks con comentarios correctos

### DHCP no se modifica
- Verificar nombres de DHCP servers: `/ip dhcp-server print`
- Comprobar comentarios de networks: `/ip dhcp-server network print`
- Asegurar coincidencia exacta entre nombres y comentarios

## 🗂️ Estructura de Archivos

```
DNS Monitor for Mikrotik/
├── DNS-monitor.rsc        # Script principal
├── readme.md              # Este archivo
├── changelog.md           # Histórico de cambios
└── examples/
    ├── dhcp-config.rsc    # Ejemplo configuración DHCP
    └── telegram-test.rsc  # Test notificaciones
```

## 📝 Desinstalación

```mikrotik
# Eliminar componentes del sistema
/system script remove [find name="DNS-Monitor-Mikrotik"]
/system scheduler remove [find name="DNS-Monitor"]
/system script remove [find name="DNS-Monitor-State"]
```

---

¿Te ha sido útil este proyecto? ¡Dale una ⭐ star en GitHub!
