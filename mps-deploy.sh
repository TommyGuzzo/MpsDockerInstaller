#!/bin/bash
set -euo pipefail

#############################################
# CONFIGURAZIONE
#############################################

BASE_DIR="/opt/mps"
VERSIONS_DIR="$BASE_DIR/versions"
CURRENT_LINK="$BASE_DIR/current"

BACKUP_DIR="/opt/mps-backups"
RETENTION=5

LOG_FILE="/var/log/mps-deploy.log"

# MPS services
MPS_SERVICES=("mpsmonitordcaclient" "mpsmonitordcamonitor")
SMTP_CONFIG="/opt/mps-deploy/smtp.secret"     


#############################################
# LOGGING
#############################################

log_info()  { echo "$(date '+%F %T') [INFO]  $1" | tee -a "$LOG_FILE"; }
log_warn()  { echo "$(date '+%F %T') [WARN]  $1" | tee -a "$LOG_FILE"; }
log_error() { echo "$(date '+%F %T') [ERROR] $1" | tee -a "$LOG_FILE"; }

#############################################
# UTILITY
#############################################

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Errore: questo script deve essere eseguito come root."
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "$VERSIONS_DIR" "$BACKUP_DIR" "/opt/mps-deploy"
    chmod 700 /opt/mps-deploy
}


#############################################
# SMTP CONFIG
#############################################

configure_smtp() {
    echo "=== Configurazione SMTP ==="
    read -p "Indirizzo email mittente: " SMTP_EMAIL
    read -s -p "Password / App Password: " SMTP_PASS
    echo

    cat > "$SMTP_CONFIG" <<EOF
defaults
auth on
tls on
tls_starttls off
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log

account default
host smtp.gmail.com
port 465
from $SMTP_EMAIL
user $SMTP_EMAIL
password $SMTP_PASS
EOF

    chmod 600 "$SMTP_CONFIG"
    chown root:root "$SMTP_CONFIG"
    echo "supporto@proced.it" > /opt/mps-deploy/dest_email.conf
    chmod 600 /opt/mps-deploy/dest_email.conf

    log_info "SMTP configurato in modo sicuro"
}

#############################################
# EMAIL ALERT
#############################################

send_mail() {
    local subject="$1"
    local body="$2"
    local dest=$(cat /opt/mps-deploy/dest_email.conf 2>/dev/null || echo "supporto@proced.it")

    if [[ -f "$SMTP_CONFIG" ]]; then
        {
            echo "To: $dest"
            echo "Subject: $subject"
            echo "Content-Type: text/plain; charset=utf-8"
            echo ""                    
            echo -e "$body"            
        } | msmtp -C "$SMTP_CONFIG" "$dest" || log_error "Invio mail fallito"
    else
        log_error "File di configurazione SMTP non trovato"
    fi
}


#############################################
# BACKUP
#############################################

create_backup() {
    ensure_dirs
    TS=$(date +%Y%m%d_%H%M%S)
    DEST="$BACKUP_DIR/backup_$TS.tar.gz"

    log_info "Creazione backup"
    tar -czf "$DEST" "$BASE_DIR"
    sha256sum "$DEST" > "$DEST.sha256"

    cleanup_old_backups

    log_info "Backup completato"
}

cleanup_old_backups() {
    COUNT=$(ls -1 "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | wc -l)
    if (( COUNT > RETENTION )); then
        REMOVE=$((COUNT - RETENTION))
        ls -1t "$BACKUP_DIR"/backup_*.tar.gz | tail -n "$REMOVE" | while read f; do
            rm -f "$f" "$f.sha256"
            log_info "Rimosso vecchio backup $f"
        done
    fi
}

restore_backup() {
    read -p "Scrivere RESTORE per confermare: " CONF
    [[ "$CONF" != "RESTORE" ]] && return

    FILE=$(ls -1t "$BACKUP_DIR"/backup_*.tar.gz | head -n1)

    sha256sum -c "$FILE.sha256"

    tar -xzf "$FILE" -C /

    log_info "Restore completato"
    send_mail "MPS Restore eseguito" "Ripristinato backup: $FILE"
}

#############################################
# MPS
#############################################

extract_version() {
    basename "$1" | grep -oE 'Setup_([0-9]+)' | cut -d_ -f2
}


health_check() {
    for svc in "${MPS_SERVICES[@]}"; do
        if ! systemctl is-active --quiet "$svc"; then
            return 1
        fi
    done
    return 0
}

install_mps() {
    echo ""
    echo "Ricerca file installer (pattern: MpsMonitor.Dca.Setup_*.run) nella directory corrente..."

    # Trova tutti i file che matchano il pattern
    mapfile -t INSTALLER_FILES < <(ls -1 MpsMonitor.Dca.Setup_*.run 2>/dev/null || true)

    if [[ ${#INSTALLER_FILES[@]} -eq 0 ]]; then
        log_error "Nessun file MpsMonitor.Dca.Setup_*.run trovato nella directory corrente"
        echo "→ Copia il file .run nella stessa directory da cui lanci mps-deploy"
        echo "→ Oppure entra nel container e copia il file con docker cp prima"
        return 1
    elif [[ ${#INSTALLER_FILES[@]} -gt 1 ]]; then
        echo "Trovati piu' file installer:"
        printf '  %d) %s\n' $(seq 0 $((${#INSTALLER_FILES[@]}-1))) "${INSTALLER_FILES[@]}"
        
        while true; do
            read -p "Quale file vuoi usare? (numero): " CHOICE
            if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 0 && CHOICE < ${#INSTALLER_FILES[@]} )); then
                FILE="${INSTALLER_FILES[$CHOICE]}"
                break
            else
                echo "Scelta non valida, riprova..."
            fi
        done
    else
        FILE="${INSTALLER_FILES[0]}"
        log_info "Trovato un solo file: $FILE"
    fi

    # Da qui in poi usiamo $FILE (è sempre valorizzato)
    VERSION=$(extract_version "$FILE")
    if [[ -z "$VERSION" ]]; then
        log_error "Impossibile estrarre la versione dal nome del file"
        return 1
    fi

    echo ""
    echo "File selezionato: $FILE"
    echo "Versione rilevata: $VERSION"
    echo ""

    # Verifica SHA256 (opzionale, ma mantenuto)
    read -p "SHA256 atteso (premi Invio per saltare): " EXPECTED
    if [[ -n "$EXPECTED" ]]; then
        ACTUAL=$(sha256sum "$FILE" | awk '{print $1}')
        if [[ "$EXPECTED" != "$ACTUAL" ]]; then
            log_error "SHA256 non corrisponde!"
            return 1
        fi
        log_info "SHA256 verificato correttamente"
    fi

    create_backup

    TARGET="$VERSIONS_DIR/$VERSION"
    mkdir -p "$TARGET"

    log_info "Installazione MPS $VERSION da $FILE"
    bash "$FILE" --target "$TARGET"

    ln -sfn "$TARGET" "$CURRENT_LINK"

    log_info "Riavvio servizi MPS..."
    systemctl restart "${MPS_SERVICES[@]}"

    HOSTNAME=$(hostname)
    IP_ADDR=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    IP_ADDR=${IP_ADDR:-"IP non rilevato"}

    if ! health_check; then
        log_error "Health check fallito dopo l'installazione"
        send_mail "MPS Upgrade FALLITO" "Health check fallito per versione $VERSION su hostname: $HOSTNAME ip:$IP_ADDR"
        rollback_mps
        return 1
    fi

    log_info "Upgrade/installazione completata con successo"
    
    BODY="Upgrade/installazione completata con successo \n\n"
    BODY+="Macchina: $HOSTNAME\n"
    BODY+="Indirizzo IP principale: $IP_ADDR\n"
    BODY+="Versione attiva: $VERSION"

    send_mail "MPS Upgrade OK" "$BODY"
}

rollback_mps() {
    PREV=$(ls -1dt "$VERSIONS_DIR"/* | sed -n '2p')
    [[ -z "$PREV" ]] && log_error "Nessuna versione precedente" && return

    ln -sfn "$PREV" "$CURRENT_LINK"
    systemctl restart "${MPS_SERVICES[@]}"

    log_warn "Rollback eseguito"
    send_mail "MPS Rollback eseguito" "Ripristinata versione: $(basename "$PREV")"
}

#############################################
# WATCHDOG INTELLIGENTE
#############################################

watchdog_check() {
    FAILED=0
    DOWN_SERVICES=()  # array per raccogliere i servizi down

    HOSTNAME=$(hostname)
    # Prendi l'IP principale (prima interfaccia non-loopback con IP)
    IP_ADDR=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    IP_ADDR=${IP_ADDR:-"IP non rilevato"}

    for svc in "${MPS_SERVICES[@]}"; do
        if ! systemctl is-active --quiet "$svc"; then
            log_warn "Servizio $svc inattivo → riavvio"
            systemctl restart "$svc"
            DOWN_SERVICES+=("$svc")
            FAILED=1
        fi
    done

    if (( FAILED == 1 )); then
        # Costruisci messaggio dettagliato
        BODY="Uno o piu' servizi MPS sono stati riavviati automaticamente. \n"
        BODY+="Macchina: $HOSTNAME \n"
        BODY+="Indirizzo IP principale: $IP_ADDR \n"
        BODY+="Servizi riavviati:"
        for svc in "${DOWN_SERVICES[@]}"; do
            BODY+="  - $svc"
        done
        BODY+="Orario: $(date '+%Y-%m-%d %H:%M:%S')\n"

        send_mail "MPS Watchdog: Riavvio servizi"    "$BODY"
    fi
}

setup_watchdog() {

    cat > /etc/cron.d/mps-watchdog <<EOF
*/5 * * * * root /opt/mps-deploy/mps-deploy.sh --watchdog
EOF

    log_info "Watchdog configurato (ogni 5 minuti)"
}

#############################################
# STATO
#############################################

system_status() {
   log_info "Versione attiva: $(readlink -f $CURRENT_LINK || echo 'Nessuna')"
    for svc in "${MPS_SERVICES[@]}"; do
        systemctl status "$svc" --no-pager || true
   done
}



daily_status_report() {
    HOSTNAME=$(hostname)
    IP_ADDR=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    IP_ADDR=${IP_ADDR:-"non rilevato"}

    # Versione attiva
    CURRENT_VERSION="Nessuna versione attiva"
    if [[ -L "$CURRENT_LINK" ]]; then
        CURRENT_VERSION=$(basename "$(readlink -f "$CURRENT_LINK")")
    fi

    # Stato servizi
    SERVICES_STATUS=""
    ALL_ACTIVE=true
    for svc in "${MPS_SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            SERVICES_STATUS+="  - $svc : ATTIVO\n"
        else
            SERVICES_STATUS+="  - $svc : DOWN\n"
            ALL_ACTIVE=false
        fi
    done

    # Messaggio
    BODY="Aggiornamento giornaliero MPS - $(date '+%Y-%m-%d %H:%M:%S')\n\n"
    BODY+="Macchina: $HOSTNAME\n"
    BODY+="Indirizzo IP principale: $IP_ADDR\n"
    BODY+="Versione MPS attiva: $CURRENT_VERSION\n"
    BODY+="\nStato servizi:\n$SERVICES_STATUS\n"

    if $ALL_ACTIVE; then
        BODY+="Tutti i servizi sono attivi\n"
    else
        BODY+="ATTENZIONE: alcuni servizi sono DOWN!\n"
    fi

    send_mail "MPS Daily Status Report - $HOSTNAME" "$BODY"
}

restart_services_mail() {
    HOSTNAME=$(hostname)
    IP_ADDR=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    IP_ADDR=${IP_ADDR:-"non rilevato"}

    # Versione attiva
    CURRENT_VERSION="Nessuna versione attiva"
    if [[ -L "$CURRENT_LINK" ]]; then
        CURRENT_VERSION=$(basename "$(readlink -f "$CURRENT_LINK")")
    fi

    # Stato servizi
    SERVICES_STATUS=""
    ALL_ACTIVE=true
    for svc in "${MPS_SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            SERVICES_STATUS+="  - $svc : ATTIVO\n"
        else
            SERVICES_STATUS+="  - $svc : DOWN\n"
            ALL_ACTIVE=false
        fi
    done

    # Messaggio
    BODY="MPS Restart Report - $(date '+%Y-%m-%d %H:%M:%S')\n\n"
    BODY+="Macchina: $HOSTNAME\n"
    BODY+="Indirizzo IP principale: $IP_ADDR\n"
    BODY+="Versione MPS attiva: $CURRENT_VERSION\n"
    BODY+="\nStato servizi:\n$SERVICES_STATUS\n"

    if $ALL_ACTIVE; then
        BODY+="Tutti i servizi sono attivi dopo il riavvio.\n"
    else
        BODY+="ATTENZIONE: alcuni servizi sono DOWN dopo il riavvio!\n"
    fi

    BODY+="\nNota: Questo report è stato generato automaticamente dopo il riavvio del container."

    send_mail "MPS Restart Report - $HOSTNAME" "$BODY"

    log_info "Report di riavvio servizi inviato via email"
}

setup_startup_report_service() {
    echo "Configurazione servizio di report all'avvio del container..."

    cat > /etc/systemd/system/mps-startup-report.service <<EOF
[Unit]
Description=MPS Startup Restart Report
After=network.target mpsmonitordcaclient.service mpsmonitordcamonitor.service
Wants=network.target

[Service]
Type=oneshot
ExecStart=/opt/mps-deploy/mps-deploy.sh --restart-report
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Ricarica systemd e abilita il servizio
    systemctl daemon-reload
    systemctl enable mps-startup-report.service

    echo "Servizio mps-startup-report.service creato e abilitato con successo"
    echo "  ExecStart: --restart-report"
    
    # Avvia subito il servizio per test
    echo "Avvio del servizio per test..."
    systemctl start mps-startup-report.service

    echo "Stato attuale del servizio:"
    systemctl status mps-startup-report.service --no-pager -l
}
 
setup_daily_report() {
    cat > /etc/cron.d/mps-daily-report <<EOF
0 10 * * * root /opt/mps-deploy/mps-deploy.sh --daily-report
EOF
    log_info "Report giornaliero configurato (ogni giorno alle 10:00)"
}
#############################################
# MENU
#############################################

main_menu() {
    while true; do
        echo ""
        echo "===== MPS DEPLOY ====="
        echo "1) Install / Upgrade MPS"
        echo "2) Rollback MPS"
        echo "3) Backup"
        echo "4) Restore"
        echo "5) Configura SMTP"
        echo "6) Watchdog setup"
        echo "7) Stato sistema"
        echo "8) Configura report giornaliero"
        echo "9) Configura report a riavvio"
        echo "0) Exit"
        read -p "Scelta: " CHOICE

        case $CHOICE in
            1) install_mps ;;
            2) rollback_mps ;;
            3) create_backup ;;
            4) restore_backup ;;
            5) configure_smtp ;;
            6) setup_watchdog ;;
            7) system_status ;;
            8) setup_daily_report ;;
            9) setup_startup_report_service ;;
            0) exit 0 ;;
            *) log_warn "Scelta non valida" ;;
        esac
    done
}

#############################################
# ENTRY POINT
#############################################

require_root
ensure_dirs

if [[ "${1:-}" == "--watchdog" ]]; then
    watchdog_check
    exit 0
elif [[ "${1:-}" == "--daily-report" ]]; then
    daily_status_report
    exit 0
elif [[ "${1:-}" == "--restart-report" ]]; then
    restart_services_mail
    exit
fi
main_menu



