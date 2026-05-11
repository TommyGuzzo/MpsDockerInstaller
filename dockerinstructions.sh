#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# SCRIPT PER LANCIARE MPS DCA IN DOCKER + ATTESA FILE INSTALLER
# ==============================================

# ────────────────────────────────────────────────
# RICHIESTA PRIVILEGI ROOT / SUDO
# ────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo ""
    echo "================================================================"
    echo " ATTENZIONE: questo script deve essere eseguito come root"
    echo "================================================================"
    echo ""
    echo "Vuoi continuare con sudo? (potrebbe essere richiesta la password)"
    echo ""

    read -n1 -p "Procedere con sudo? [S]ì / [N]o : " risposta
    echo ""

    if [[ ! "$risposta" =~ ^[SsYy]$ ]]; then
        echo "Operazione annullata."
        exit 1
    fi  

    echo "Rilancio con sudo..."
    echo ""

   
    exec sudo -E bash "$0" "$@"
    # Se exec fallisce (es. sudo negato) esce qui
    echo "Impossibile eseguire sudo. Esci."
    exit 1
fi
# ==============================================
# CONFIGURAZIONE MOTD TUNNEL SSH
# ==============================================

MOTD_FILE="/etc/update-motd.d/99-ssh-tunnel"

if [[ -f "$MOTD_FILE" ]]; then
    echo "MOTD SSH Tunnel già configurato. Salto questa parte."
else
    echo "Configurazione messaggio SSH (MOTD)..."

    cat << 'EOF' > "$MOTD_FILE"
#!/bin/bash

IP=$(hostname -I | awk '{print $1}')
echo "#---------------"
echo "Per visualizzare la home page aprire tunnel ssh con comando:"
echo ""
echo "ssh -L 12312:localhost:12312 radxa@$IP"
echo ""
echo "Successivamente aprire sul browser:"
echo "http://localhost:12312/home"
echo "#---------------"
EOF

    chmod +x "$MOTD_FILE"
    echo "MOTD configurato correttamente."
fi

echo ""

# ==============================================
# FIX SOURCES PER DEBIAN BULLSEYE (EOL)
# ==============================================

fix_bullseye_sources() {
    echo "=== Fix repositories per Debian Bullseye (EOL) ==="

    # Rimuovi il file problematico
    if [[ -f /etc/apt/sources.list.d/50-bullseye-security.list ]]; then
        echo "→ Rimozione di 50-bullseye-security.list"
        rm -f /etc/apt/sources.list.d/50-bullseye-security.list
    fi

    # Backup
    mkdir -p "/etc/apt/sources.list.d/backup_$(date +%Y%m%d_%H%M)"
    cp /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/backup_* 2>/dev/null || true

    # Correggi i repository Debian
    echo "→ Aggiornamento URL su archive.debian.org..."
    for file in /etc/apt/sources.list.d/50-*.list; do
        if [[ -f "$file" ]]; then
            echo "   Elaboro: $(basename "$file")"
            sed -i 's|https\?://deb.debian.org/debian|http://archive.debian.org/debian|g' "$file"
        fi
    done

    if [[ -f /etc/apt/sources.list ]]; then
        sed -i 's|https\?://deb.debian.org/debian|http://archive.debian.org/debian|g' /etc/apt/sources.list
    fi

    echo "→ Eseguo apt update..."
    apt-get update -qq || echo "⚠ apt update ha riportato errori (normale su Bullseye EOL)"

    echo "Correzione repositories Bullseye completata."
    touch /etc/apt/sources.list.d/.bullseye-fix-done   # ← segnaposto
}

check_and_fix_bullseye() {
    # Check se il fix è già stato fatto
    if [[ -f /etc/apt/sources.list.d/.bullseye-fix-done ]]; then
        echo "Fix repositories Bullseye già applicato in precedenza. Salto."
        return 0
    fi

    echo "Controllo versione del sistema operativo..."

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "debian" && "$VERSION_CODENAME" == "bullseye" ]]; then
            echo "→ Rilevato: Debian Bullseye (EOL)"
            fix_bullseye_sources
        else
            echo "→ Sistema rilevato: $PRETTY_NAME → Non è Bullseye, salto il fix."
        fi
    else
        echo "⚠ Impossibile determinare la versione del SO. Salto il fix Bullseye."
    fi
}   

echo "=======check fix repository======="
check_and_fix_bullseye

# ==============================================
# CHECK DOCKER INSTALLATO
# ==============================================
if ! command -v docker &> /dev/null || ! docker --version &> /dev/null; then
    echo ""
    echo "============================================"
    echo "  DOCKER NON TROVATO SUL SISTEMA"
    echo "============================================"
    echo ""
    echo "Per eseguire questo script è necessario Docker."
    echo "Vuoi installarlo ora con 'apt install docker.io'?"
    echo "(verrà installata la versione dai repository Ubuntu)"
    echo ""

    read -n1 -p "Installare Docker ora? [S]ì / [N]o : " INSTALL_DOCKER
    echo ""

    if [[ "$INSTALL_DOCKER" =~ ^[SsYy]$ ]]; then
        
        echo "Inizio installazione docker.io ..."
        
        sudo apt update
        sudo apt install -y docker.io 

        # Aggiungi utente corrente al gruppo docker
        sudo usermod -aG docker "$USER"

        echo ""
        echo "Docker installato con successo."
        echo "Aggiunto $USER al gruppo docker."
        
    #    echo "FAI RIPARTIRE LO SCRIPT SE BLOCCATO"
        if groups | grep -q docker; then
            echo "Gruppo docker già attivo. Docker pronto."
            docker --version
        else
            echo "Riavvio dello script con il nuovo gruppo docker..."
            echo "──────────────────────────────────────────────────────"

            # Riavvia lo script stesso nel nuovo gruppo
            exec sg docker "$0" "$@"

            # Se arriva qui, qualcosa è andato storto
            echo "Errore nel riavvio automatico dello script."
            exit 1
        fi
    else
        echo "Installazione annullata."
        echo "Installa manualmente Docker con:"
        echo "  sudo apt update && sudo apt install docker.io"
        echo "Poi riprova questo script."
        exit 1
    fi
else
    echo "Docker già installato  versione: $(docker --version)"
    echo ""
fi

IMAGE_NAME="mps-dca-base:latest"
CONTAINER_NAME_DEFAULT="mps-dca"


echo ""
echo "============================================"
echo "  SETUP CONTAINER MPS DCA - PROCED"
echo "============================================"
echo ""

# ==============================================
# 1. Chiedi nome azienda
# ==============================================
while true; do
    read -rp "Inserisci il NOME AZIENDA : " AZIENDA

    if [[ -z "$AZIENDA" ]]; then
        echo "Errore: il nome azienda è obbligatorio!"
        continue
    fi

    echo ""
    echo "Hai inserito: $AZIENDA"
    read -rp "Confermi? (S/n): " CONF
    CONF=${CONF:-S}

    if [[ "$CONF" =~ ^[SsYy]$ ]]; then
        break
    fi

    echo "Reinserisci il nome azienda."
    echo ""
done

# Normalizza per container name
CONTAINER_NAME=$(echo "$AZIENDA" | tr -s '[:space:]' '-' | tr -cd '[:alnum:]-_' | tr '[:upper:]' '[:lower:]')
CONTAINER_NAME="${CONTAINER_NAME:-mps-dca-fallback}"

echo ""
echo " Nome container: $CONTAINER_NAME"
echo " Hostname container (per email MPS): $AZIENDA"
echo ""

read -p "Confermi? (S/n): " CONF
CONF=${CONF:-S}
[[ "$CONF" != "S" && "$CONF" != "s" && "$CONF" != "y" && "$CONF" != "Y" ]] && { echo "Annullato."; exit 0; }

# ==============================================
# 2. Loop di attesa per il file installer .run
# ==============================================
echo ""
echo "Ricerca file installer (pattern: MpsMonitor.Dca.Setup_*.run) ..."

while true; do
    # Trova tutti i file che matchano il pattern
     mapfile -t INSTALLER_FILES < <(ls -1 MpsMonitor.Dca.Setup_*.run 2>/dev/null || true)

    if [[ ${#INSTALLER_FILES[@]} -eq 0 ]]; then
        echo ""
        echo "┌────────────────────────────────────────────────────────────┐"
        echo "│  ATTENZIONE: nessun file MpsMonitor.Dca.Setup_*.run trovato│"
        echo "│                                                            │"
        echo "│  1. Copia il file installer nella stessa cartella di       │"
        echo "│     questo script                                          │"
        echo "│  2. Premi S quando hai finito                              │"
        echo "└────────────────────────────────────────────────────────────┘"
        echo ""

        read -n1 -p "Premi S per riprovare (o Ctrl+C per uscire): " KEY
        echo ""
        if [[ "$KEY" == "S" || "$KEY" == "s" ]]; then
            continue
        else
            echo "Uscita su richiesta."
            exit 0
        fi
    elif [[ ${#INSTALLER_FILES[@]} -gt 1 ]]; then
        echo "Trovati più file .run:"
        printf '  %d) %s\n' $(seq 0 $((${#INSTALLER_FILES[@]}-1))) "${INSTALLER_FILES[@]}"
        read -p "Quale file vuoi usare? (numero): " CHOICE
        if [[ ! "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 0 || CHOICE >= ${#INSTALLER_FILES[@]} )); then
            echo "Scelta non valida, riprovo..."
            continue
        fi
        INSTALLER_FILE="${INSTALLER_FILES[$CHOICE]}"
        break
    else
        INSTALLER_FILE="${INSTALLER_FILES[0]}"
        echo "Trovato: $INSTALLER_FILE"
        break
    fi
done

echo ""
echo "File installer selezionato: $INSTALLER_FILE"
echo ""

# ==============================================
# 3. Controllo immagine
# ==============================================
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Immagine $IMAGE_NAME non trovata."
    docker build -t "$IMAGE_NAME" .     
fi

# ==============================================
# 4. Gestione container
# ==============================================
if docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container $CONTAINER_NAME esiste già."
    docker start "$CONTAINER_NAME" &>/dev/null || true
else
    echo "Creazione container '$CONTAINER_NAME' ..."

    docker run -d \
        --name "$CONTAINER_NAME" \
        --hostname "$AZIENDA" \
        --privileged \
        --network host \
        --cgroupns=host \
        --tmpfs /run \
        --tmpfs /run/lock \
        --tmpfs /tmp \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v mps-opt:/opt/mps \
        -v mps-backups:/opt/mps-backups \
        -v mps-logs:/var/log \
        -v /usr/share/zoneinfo/Europe/Rome:/etc/localtime:ro \
        -v /etc/timezone:/etc/timezone:ro \
        --restart unless-stopped \
        "$IMAGE_NAME"
fi
# ==============================================
# 5. Copia il file installer nel container
# ==============================================
echo "Copia file installer nel container..."
sleep 2
docker cp "$INSTALLER_FILE" "$CONTAINER_NAME:/opt/mps-deploy"

echo "Rendo eseguibile il file installer dentro il container..."
if docker exec "$CONTAINER_NAME" chmod +x /opt/mps-deploy/"$(basename "$INSTALLER_FILE")"; then
    echo "File reso eseguibile con successo"
else
    echo "ERRORE: impossibile rendere eseguibile il file "
    exit 1
fi

echo "Copia file installer nel container..."
docker cp mps-deploy.sh "$CONTAINER_NAME:/opt/mps-deploy"
echo " Rendo eseguibile mps-deploy.sh"
if docker exec "$CONTAINER_NAME" chmod +x /opt/mps-deploy/mps-deploy.sh; then
    echo "mps-deploy.sh reso eseguibile"
else
    echo "ERRORE: impossibile rendere eseguibile mps-deploy.sh"
    exit 1
fi


echo ""
echo "============================================"
echo " Container: $CONTAINER_NAME"
echo " Hostname:  $AZIENDA"
echo " Installer: /opt/mps-deploy(copiato)"
echo "============================================"
echo ""

echo "Il file è stato copiato in /opt/mps-deploy"
echo "Ora puoi entrare nel container e lanciare:"
echo "  mps-deploy"
echo " opzione 1) Install / Upgrade MPS"
echo " percorso: /opt/mps-deploy"
echo ""

# ==============================================
# 6. Entra nel container (direttamente nella directory giusta)
# ==============================================
read -p "Vuoi entrare ora nel container? (S/n): " ENTER
ENTER=${ENTER:-S}
if [[ "$ENTER" == "S" || "$ENTER" == "s" ]]; then
    echo "Entro nel container direttamente in /opt/mps-deploy..."
    echo "" 
    echo "Una volta dentro, per avviare il deploy:"
    echo "  ./mps-deploy.sh"
    echo ""
    echo "Digita 'exit' quando hai finito."
    echo ""

    # Entra in bash, cambia directory automaticamente e lascia l'utente lì
    docker exec -it "$CONTAINER_NAME" bash -c "cd /opt/mps-deploy && exec bash"

else
    echo "Ok, non entro nel container."
fi

# ==============================================
# 7. BACKUP SICURO DEI FILE SU HOST (solo root)
# ==============================================

echo ""
echo "Creazione backup sicuro dei file di deploy..."

sudo mkdir -p /opt/mps-docker

# Copia tutti i file della directory corrente
sudo cp -r . /opt/mps-docker/ 2>/dev/null || true


# Permessi ultra restrittivi: solo root può accedere
sudo chown -R root:root /opt/mps-docker
sudo chmod -R 700 /opt/mps-docker

echo "Backup creato in: /opt/mps-docker"
echo "    Solo l'utente root può accedere a questa cartella."
echo "    Tutti i file del progetto (Dockerfile, script, installer, ecc.) sono stati salvati."
echo ""

# ==============================================
# 8. PULIZIA DELLA CARTELLA ORIGINE (dopo il backup)
# ==============================================

echo ""
echo "Pulizia della cartella di origine in corso..."

# Chiedi conferma prima di eliminare
read -p "Vuoi ELIMINARE tutti i file dalla cartella corrente? (S/n): " CONFIRM_CLEAN
CONFIRM_CLEAN=${CONFIRM_CLEAN:-n}

if [[ "$CONFIRM_CLEAN" =~ ^[SsYy]$ ]]; then
    echo "Pulizia in corso..."

    # Elimina tutto tranne dockerinstructions.sh
    shopt -s dotglob nullglob   # per includere file nascosti e non dare errore se non c'è nulla

    for file in *; do
        if [[ "$file" != "dockerinstructions.sh" && "$file" != "bridge-setup.sh"  ]]; then
            sudo rm -rf "$file" 2>/dev/null || true
        fi
    done   
    
    echo "Tutti i file sono stati eliminati dalla cartella corrente."
    echo "   Rimane solo 'dockerinstructions.sh'e 'bridge-setup.sh'."
else
    echo "Pulizia annullata. I file rimangono nella cartella corrente."
fi

echo ""
echo "Script terminato."
echo "Per rientrare manualmente nel container:"
echo "  sudo docker exec -it $CONTAINER_NAME bash -c 'cd /opt/mps-deploy && exec bash'" 
echo ""