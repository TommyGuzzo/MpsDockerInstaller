# =============================================================================
# Immagine base con systemd + .NET 6 per MPS DCA
# =============================================================================
FROM --platform=linux/arm64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Copia tutto il contesto di build in una directory temporanea
# (così possiamo fare pattern matching sul nome del file)
COPY . /build-context/

# Pacchetti base + .NET 6 runtime + tool per lo script
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gnupg \
    apt-transport-https \
    libc6 \
    libicu70 \
    libssl3 \
    libunwind8 \
    zlib1g \
    tar \
    gzip \
    systemd \
    systemd-sysv \
    dbus \
    msmtp \
    cron \
    sudo \
    htop \
    iproute2 \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Installazione .NET 6 per Raspberry Pi (ARM64) - usando i pacchetti ufficiali di Ubuntu
RUN apt-get update && apt-get install -y --no-install-recommends \
    dotnet6 \
    aspnetcore-runtime-6.0 \
    && rm -rf /var/lib/apt/lists/*


# Prepara le directory usate dal tuo script
RUN mkdir -p /opt/mps/versions \
             /opt/mps-backups \
             /opt/mps-deploy \
             /var/log \
    && touch /var/log/mps-deploy.log \
    && chmod 644 /var/log/mps-deploy.log



# Pulizia (opzionale ma buona pratica)
RUN rm -rf /build-context

# =============================================================================
# Resto invariato
# =============================================================================
VOLUME ["/opt/mps", "/opt/mps-backups", "/var/log"]

STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/lib/systemd/systemd", "--system"]
