# ===================================================================
# DNS MONITOR FOR MIKROTIK v1.0
# ===================================================================
# Descripción: Sistema completo de monitoreo DNS con failover automático
#              y notificaciones Telegram para MikroTik RouterOS v7+
# 
# Autor: eZx09 (https://github.com/eZx09/tools/)
# Fecha: 24/09/2025
# Versión: 1.0 STABLE
# Compatibilidad: RouterOS 7.x+
# sss
# FUNCIONALIDADES PRINCIPALES:
# - Monitoreo continuo de Pi-hole cada minuto (configurable)
# - Failover automático a DNS backup en caso de fallo
# - Restore automático cuando Pi-hole vuelve a funcionar
# - Configuración automática de DHCP servers (lease time + DNS)  
# - Notificaciones detalladas por Telegram
# - 4 modos configurables de DNS para el router
# - Detección con doble verificación para evitar falsos positivos
# - Estado persistente que sobrevive reinicios
# 
# PREREQUISITOS:
# - RouterOS v7.0 o superior
# - Acceso a internet para notificaciones Telegram
# - Bot de Telegram configurado con token válido
# - Pi-hole o servidor DNS primario accesible via ping
# - Redes DHCP configuradas con comentarios específicos
# 
# INSTALACIÓN:
# 1. Copiar y pegar este script completo en terminal RouterOS
# 2. Modificar las variables de configuración según tu entorno
# 3. Verificar que las redes DHCP tengan comentarios correctos
# 4. El script se activa automáticamente cada minuto
# 
# DESINSTALACIÓN:
# /system script remove [find name="DNS-Monitor-Mikrotik"]
# /system scheduler remove [find name="DNS-Monitor"]
# /system script remove [find name="DNS-Monitor-State"]
# 
# COMANDOS ÚTILES:
# - Test manual: /system script run DNS-Monitor-Mikrotik
# - Ver logs: /log print where topics~"script" 
# - Ver estado: /system script print where name="DNS-Monitor-State"
# - Pausar monitoreo: /system scheduler disable DNS-Monitor
# - Reanudar monitoreo: /system scheduler enable DNS-Monitor
# - Ver estadísticas scheduler: /system scheduler print where name="DNS-Monitor"
# ===================================================================

# LIMPIEZA PREVIA DE VERSIONES ANTERIORES
/system script remove [find name="DNS-Monitor-Mikrotik"]
/system script remove [find name="DNS-Monitor-State"]
/system scheduler remove [find name="DNS-Monitor"]

/system script add name="DNS-Monitor-Mikrotik" policy=read,write,test,reboot source={
    # =============================================================
    # CONFIGURACIÓN PRINCIPAL - PERSONALIZAR SEGÚN TU ENTORNO
    # =============================================================
    
    # DIRECCIÓN IP DEL SERVIDOR DNS PRIMARIO (Pi-hole, AdGuard, etc.)
    # Esta IP será monitoreada con ping cada minuto
    :global PIHOLEIP "IP_DNS_PRIMARIO"
    
    # SERVIDORES DNS DE RESPALDO (separados por coma, sin espacios)
    # Se utilizarán cuando el DNS primario falle
    # Ejemplos: "8.8.8.8,1.1.1.1" o "9.9.9.9,149.112.112.112"
    :global BACKUPDNS "1.1.1.1,8.8.8.8"
    
    # TIEMPO DE LEASE DHCP DURANTE FAILOVER
    # Formato RouterOS: 10s, 5m, 1h, 1d, etc.
    # Se aplica a todas las redes DHCP durante el fallo
    :global LTFAILOVER "10m"
    
    # CONFIGURACIÓN BOT TELEGRAM
    # Token del bot (obtener de @BotFather en Telegram)
    :global TGTOKEN "TU_TOKEN_TELEGRAM_AQUI"
    # Chat ID donde enviar notificaciones (obtener de @userinfobot)
    :global TGCHAT "TU_TELEGRAM_CHATID_AQUI"
    
    # MODO DE CONFIGURACIÓN DNS DEL ROUTER
    # Controla cómo el router maneja sus propios DNS servers:
    #
    # "none"        - No modifica DNS del router, solo actúa en redes DHCP
    #                 Útil si quieres manejar DNS del router manualmente
    #
    # "backup-only" - Router siempre usa solo DNS backup 
    #                 Nunca configura Pi-hole en el router mismo
    #                 Útil para setups donde router no debe usar Pi-hole
    #
    # "balanced"    - Comportamiento estándar (RECOMENDADO)
    #                 Normal: Pi-hole + DNS backup en router
    #                 Failover: Solo DNS backup en router
    #                 Mejor balance entre filtrado y disponibilidad
    #
    # "pihole-only" - Máximo filtrado posible
    #                 Normal: Solo Pi-hole en router  
    #                 Failover: Solo DNS backup en router
    #                 Máximo bloqueo pero menos redundancia
    :global ROUTERDNSMODE "backup-only"
    
    # =============================================================
    # CONFIGURACIÓN AVANZADA DHCP
    # =============================================================
    # 
    # IMPORTANTE: Para que el script funcione correctamente, tus
    # DHCP Networks deben tener comentarios que coincidan exactamente
    # con los nombres de los DHCP Servers:
    #
    # Ejemplo de configuración correcta:
    # DHCP Server "dhcp-lan" -> DHCP Network comment="dhcp-lan" 
    # DHCP Server "dhcp-iot" -> DHCP Network comment="dhcp-iot"
    #
    # El script busca servers llamados "dhcp-lan" y "dhcp-iot" y
    # modifica sus networks correspondientes basándose en el comentario.
    #
    # TIEMPOS DE LEASE NORMALES (cuando Pi-hole funciona):
    # - dhcp-lan: 30 minutos (clientes frecuentes, renovación rápida)
    # - dhcp-iot: 2 horas (dispositivos IoT, menos cambios)
    #
    # Durante failover, ambas redes usan el tiempo configurado en LTFAILOVER
    #
    # PARA AÑADIR MÁS REDES DHCP:
    # 1. Crear DHCP server con nombre descriptivo (ej: "dhcp-guest")
    # 2. Crear DHCP network con comment="dhcp-guest" 
    # 3. Añadir lógica similar en las secciones FAILOVER y RESTORE
    # 4. Ejemplo de código a añadir:
    #    :if ($name = "dhcp-guest") do={
    #        /ip dhcp-server set $s lease-time=1h
    #        :foreach n in=[/ip dhcp-server network find where comment="$name"] do={
    #            /ip dhcp-server network set $n dns-server=$PIHOLEIP
    #        }
    #        :set dhcpChanges ($dhcpChanges . "%0Adhcp-guest -> DNS: " . $PIHOLEIP . " | Lease: 1h")
    #    }
    
    # =============================================================
    # SISTEMA INTERNO - NO MODIFICAR SIN CONOCIMIENTO TÉCNICO
    # =============================================================
    
    # Crear variable de estado persistente que sobrevive reinicios
    # Almacena el estado actual del sistema: "active" o "failover"
    :if ([:len [/system script find name="DNS-Monitor-State"]] = 0) do={
        /system script add name="DNS-Monitor-State" source=":return" comment="active"
    }
    
    # Obtener estado anterior para evitar notificaciones duplicadas
    :local EstadoActual [/system script get [find name="DNS-Monitor-State"] comment]
    
    # Obtener información del sistema para los mensajes de notificación
    :local fecha [/system clock get date]
    :local hora [/system clock get time]
    :local uptime [/system resource get uptime]
    :local rname [/system identity get name]
    
    # =============================================================
    # ALGORITMO PRINCIPAL DE MONITOREO
    # =============================================================
    # 
    # LÓGICA DE DETECCIÓN:
    # - Ping 4 veces al DNS primario
    # - Si fallan 2 o más pings (< 3 exitosos), considera DOWN
    # - Espera 30 segundos y realiza segunda verificación
    # - Solo actúa si ambas verificaciones confirman el estado
    # 
    # PREVENCIÓN DE FALSOS POSITIVOS:
    # - Doble verificación con delay entre checks
    # - Solo cambia estado si confirmación es consistente  
    # - Logs detallados para troubleshooting
    
    # PRIMERA FASE: DETECCIÓN DE FALLO DNS PRIMARIO
    :if ([/ping $PIHOLEIP count=4] < 3) do={
        # Solo proceder si no estamos ya en failover (evitar spam)
        :if ($EstadoActual != "fallback") do={
            :log warning "DNS Monitor: Pi-hole DOWN - Verificando..."
            :delay 30s
            
            # SEGUNDA VERIFICACIÓN: Confirmar el fallo antes de actuar
            # Esto previene failovers por pérdida temporal de conectividad
            :if ([/ping $PIHOLEIP count=4] < 3) do={
                :log error "DNS Monitor: FAILOVER ACTIVADO"
                
                # =============================================================
                # CONFIGURACIÓN DNS DEL ROUTER DURANTE FAILOVER
                # =============================================================
                :local routerDNSText ""
                :if ($ROUTERDNSMODE = "none") do={
                    :set routerDNSText "Sin cambios"
                } else={
                    :if ($ROUTERDNSMODE = "backup-only") do={
                        /ip dns set servers=$BACKUPDNS allow-remote-requests=yes
                        :set routerDNSText $BACKUPDNS
                    } else={
                        :if ($ROUTERDNSMODE = "pihole-only") do={
                            /ip dns set servers=$BACKUPDNS allow-remote-requests=yes
                            :set routerDNSText $BACKUPDNS
                        } else={
                            # DEFAULT: balanced - solo backup en failover
                            /ip dns set servers=$BACKUPDNS allow-remote-requests=yes
                            :set routerDNSText $BACKUPDNS
                        }
                    }
                }
                
                # =============================================================
                # CONFIGURACIÓN DHCP DURANTE FAILOVER
                # =============================================================
                # Recorre todos los DHCP servers y modifica los configurados
                :local dhcpChanges ""
                :foreach s in=[/ip dhcp-server find] do={
                    :local name [/ip dhcp-server get $s name]
                    
                    # Aplicar cambios solo a servers específicos
                    # Modifica esta condición para añadir más redes
                    :if ($name = "dhcp-lan" or $name = "dhcp-iot") do={
                        # Cambiar lease time a tiempo de failover (más corto)
                        /ip dhcp-server set $s lease-time=$LTFAILOVER
                        
                        # Cambiar DNS en las networks correspondientes
                        # Busca networks cuyo comentario coincida con el nombre del server
                        :foreach n in=[/ip dhcp-server network find where comment="$name"] do={
                            /ip dhcp-server network set $n dns-server=$BACKUPDNS
                        }
                        
                        # Construir mensaje informativo para Telegram
                        :set dhcpChanges ($dhcpChanges . "%0A" . $name . " -> DNS: " . $BACKUPDNS . " | Lease: " . $LTFAILOVER)
                    }
                }
                
                # Actualizar estado persistente para la próxima ejecución
                /system script set [find name="DNS-Monitor-State"] comment="fallback"
                
                # =============================================================
                # NOTIFICACIÓN TELEGRAM - FAILOVER
                # =============================================================
                # Construir mensaje detallado con toda la información relevante
                :local mensaje ("[MikroTik] DNS FAILOVER%0ARouter: " . $rname . "%0APi-hole: DOWN%0AFecha: " . $fecha . " " . $hora . "%0AUptime: " . $uptime . $dhcpChanges . "%0A%0AMode: " . $ROUTERDNSMODE . "%0ARouter DNS: " . $routerDNSText)
                :local telegramURL ("https://api.telegram.org/bot" . $TGTOKEN . "/sendMessage?chat_id=" . $TGCHAT . "&text=" . $mensaje)
                /tool fetch url=$telegramURL keep-result=no
                
                :log info "DNS Monitor: FAILOVER completado"
            }
        }
    } else={
        # SEGUNDA FASE: DNS PRIMARIO FUNCIONA - VERIFICAR SI NECESITAMOS RESTORE
        :if ($EstadoActual != "active") do={
            :log info "DNS Monitor: Pi-hole UP - Verificando..."
            :delay 15s
            
            # VERIFICACIÓN DE RESTORE: confirmar que DNS funciona bien
            # Ping más conservador (2 de 2) para confirmar estabilidad
            :if ([/ping $PIHOLEIP count=2] = 2) do={
                :log info "DNS Monitor: RESTORE ACTIVADO"
                
                # =============================================================
                # CONFIGURACIÓN DNS DEL ROUTER DURANTE RESTORE
                # =============================================================
                :local routerDNSText ""
                :if ($ROUTERDNSMODE = "none") do={
                    :set routerDNSText "Sin cambios"
                } else={
                    :if ($ROUTERDNSMODE = "backup-only") do={
                        /ip dns set servers=$BACKUPDNS allow-remote-requests=yes
                        :set routerDNSText $BACKUPDNS
                    } else={
                        :if ($ROUTERDNSMODE = "pihole-only") do={
                            /ip dns set servers=$PIHOLEIP allow-remote-requests=yes
                            :set routerDNSText $PIHOLEIP
                        } else={
                            # DEFAULT: balanced - pihole + backup
                            :local dnsString ($PIHOLEIP . "," . $BACKUPDNS)
                            /ip dns set servers=$dnsString allow-remote-requests=yes
                            :set routerDNSText $dnsString
                        }
                    }
                }
                
                # =============================================================
                # RESTAURACIÓN DHCP A CONFIGURACIÓN NORMAL
                # =============================================================
                :local dhcpChanges ""
                :foreach s in=[/ip dhcp-server find] do={
                    :local name [/ip dhcp-server get $s name]
                    
                    # dhcp-lan: Clientes regulares, lease más corto (30 min)
                    :if ($name = "dhcp-lan") do={
                        /ip dhcp-server set $s lease-time=30m
                        :foreach n in=[/ip dhcp-server network find where comment="$name"] do={
                            /ip dhcp-server network set $n dns-server=$PIHOLEIP
                        }
                        :set dhcpChanges ($dhcpChanges . "%0Adhcp-lan -> DNS: " . $PIHOLEIP . " | Lease: 30m")
                    }
                    
                    # dhcp-iot: Dispositivos IoT, lease más largo (2 horas)
                    :if ($name = "dhcp-iot") do={
                        /ip dhcp-server set $s lease-time=2h
                        :foreach n in=[/ip dhcp-server network find where comment="$name"] do={
                            /ip dhcp-server network set $n dns-server=$PIHOLEIP
                        }
                        :set dhcpChanges ($dhcpChanges . "%0Adhcp-iot -> DNS: " . $PIHOLEIP . " | Lease: 2h")
                    }
                }
                
                # Actualizar estado persistente
                /system script set [find name="DNS-Monitor-State"] comment="active"
                
                # =============================================================
                # NOTIFICACIÓN TELEGRAM - RESTORE
                # =============================================================
                :local mensaje ("[MikroTik] DNS RESTORE%0ARouter: " . $rname . "%0APi-hole: UP%0AFecha: " . $fecha . " " . $hora . "%0AUptime: " . $uptime . $dhcpChanges . "%0A%0AMode: " . $ROUTERDNSMODE . "%0ARouter DNS: " . $routerDNSText)
                :local telegramURL ("https://api.telegram.org/bot" . $TGTOKEN . "/sendMessage?chat_id=" . $TGCHAT . "&text=" . $mensaje)
                /tool fetch url=$telegramURL keep-result=no
                
                :log info "DNS Monitor: RESTORE completado"
            }
        }
    }
    
    # Log de finalización exitosa para troubleshooting
    :log info "DNS Monitor: Ciclo completado OK"
}

# =============================================================
# PROGRAMADOR AUTOMÁTICO (SCHEDULER)
# =============================================================
# Ejecuta el script cada minuto desde el arranque del sistema
# Políticas requeridas: read,write,test,reboot para funcionar correctamente
/system scheduler add name="DNS-Monitor" interval=1m start-time=startup \
    on-event="/system script run DNS-Monitor-Mikrotik" \
    policy=read,write,test,reboot

# =============================================================
# INICIALIZACIÓN DEL ESTADO DEL SISTEMA
# =============================================================
# Crear script auxiliar para almacenar estado persistente
# Inicializa en "active" asumiendo que el sistema inicia correctamente
/system script add name="DNS-Monitor-State" source=":return" comment="active"

# =============================================================
# CONFIRMACIÓN DE INSTALACIÓN
# =============================================================
:put "=================================================================="
:put "         DNS MONITOR FOR MIKROTIK v1.0 - INSTALADO              "
:put "=================================================================="
:put "Script: DNS-Monitor-Mikrotik                                     "
:put "Scheduler: DNS-Monitor (ejecuta cada 1 minuto)                   "
:put "Estado: DNS-Monitor-State                                        "
:put "                                                                  "
:put "                                                                  "
:put "COMANDOS UTILES:                                                 "
:put "Test manual: /system script run DNS-Monitor-Mikrotik             "
:put "Ver logs: /log print where topics~\"script\"                     "
:put "Ver estado: /system scheduler print where name=\"DNS-Monitor\"   "
:put "Pausar: /system scheduler disable DNS-Monitor                    "
:put "Reanudar: /system scheduler enable DNS-Monitor                   "
:put "                                                                  "
:put "MONITOREO ACTIVO - Sistema funcionando automaticamente          "
:put "=================================================================="
