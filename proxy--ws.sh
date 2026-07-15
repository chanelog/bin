#!/usr/bin/env bash
#
# proxy--ws.sh
# Installation complète wstunnel + managing iptables + service systemd
# Pare-feu géré uniquement via iptables + persistance netfilter-persistent

set -e

WSTUNNEL_URL="https://github.com/erebe/wstunnel/releases/download/v10.5.1/wstunnel_10.5.1_linux_amd64.tar.gz"
WSTUNNEL_TAR="wstunnel_10.5.1_linux_amd64.tar.gz"
WSTUNNEL_BIN="/usr/local/bin/wstunnel"
PROXY_WS_BIN="/usr/local/bin/proxy--ws"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/proxy--ws.service"

PORT=8880
CHAIN_NAME="KIGHMU_WSPROXY"

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Ce script doit être exécuté en root."
        exit 1
    fi
}

install_dependencies() {
    echo "Installation des dépendances nécessaires (iptables et netfilter-persistent)..."
    apt-get update -y
    apt-get install -y iptables iptables-persistent netfilter-persistent wget
}

setup_iptables_rules() {
    echo "Configuration des règles iptables pour autoriser le port $PORT..."

    # Création d'une chaîne dédiée si pas déjà existante
    iptables -L $CHAIN_NAME -n >/dev/null 2>&1 || iptables -N $CHAIN_NAME

    # Flush la chaîne pour éviter doublons
    iptables -F $CHAIN_NAME

    # Autoriser le port TCP 8880 dans INPUT
    iptables -A $CHAIN_NAME -p tcp --dport $PORT -j ACCEPT

    # Insérer la chaîne de règles custom en haut de INPUT si pas déjà insérée
    if ! iptables -C INPUT -j $CHAIN_NAME 2>/dev/null; then
        iptables -I INPUT 1 -j $CHAIN_NAME
    fi

    # Persister les règles
    netfilter-persistent save
    echo "Règles iptables appliquées et sauvegardées."
}

install_wstunnel() {
    if [ -x "$WSTUNNEL_BIN" ]; then
        echo "wstunnel déjà installé à $WSTUNNEL_BIN, installation ignorée."
        return
    fi
    echo "Téléchargement de wstunnel..."
    wget -O "$WSTUNNEL_TAR" "$WSTUNNEL_URL"
    echo "Extraction..."
    tar -xzf "$WSTUNNEL_TAR"
    if [ ! -f "wstunnel" ]; then
        echo "Erreur : binaire wstunnel non trouvé."
        exit 1
    fi
    echo "Installation de wstunnel dans $WSTUNNEL_BIN..."
    chmod +x wstunnel
    mv wstunnel "$WSTUNNEL_BIN"
    rm -f "$WSTUNNEL_TAR"
    echo "wstunnel installé."
}

create_proxy_ws_script() {
    echo "Création du script proxy--ws avec domaine $DOMAIN sur port $PORT..."
    cat > "$PROXY_WS_BIN" << EOF
#!/usr/bin/env bash
# proxy--ws lance wstunnel en mode serveur WebSocket tunnel SSH

DOMAIN="${DOMAIN:-0.0.0.0}"
WS_LISTEN_ADDR="0.0.0.0"
WS_LISTEN_PORT="$PORT"
BACKEND_HOST="127.0.0.1"
BACKEND_PORT="22"
WSTUNNEL_BIN="/usr/local/bin/wstunnel"
PID_FILE="/var/run/proxy--ws.pid"
LOG_FILE="/var/log/proxy--ws.log"

echo "Démarrage du tunnel WebSocket sur ws://$DOMAIN:$WS_LISTEN_PORT vers $BACKEND_HOST:$BACKEND_PORT"
exec $WSTUNNEL_BIN server "ws://$DOMAIN:$WS_LISTEN_PORT" --restrict-to "$BACKEND_HOST:$BACKEND_PORT"
EOF
    chmod +x "$PROXY_WS_BIN"
    echo "Script proxy--ws créé."
}

create_systemd_service() {
    echo "Création du service systemd proxy--ws..."
    cat > "$SYSTEMD_SERVICE_FILE" << EOF
[Unit]
Description=Proxy WebSocket SSH Tunnel (proxy--ws)
After=network.target

[Service]
Type=simple
User=root
ExecStart=$PROXY_WS_BIN
Restart=always
RestartSec=5
StartLimitIntervalSec=0
KillMode=process
StandardOutput=append:/var/log/proxy--ws.log
StandardError=append:/var/log/proxy--ws.err

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable proxy--ws.service
    systemctl start proxy--ws.service
    echo "Service proxy--ws activé et démarré."
}

main() {
    ensure_root
    if [[ -z "$DOMAIN" ]]; then
        echo "Erreur : la variable DOMAIN doit être définie avant d'exécuter ce script."
        exit 1
    fi
    install_dependencies
    setup_iptables_rules
    install_wstunnel
    create_proxy_ws_script
    create_systemd_service
    echo "Installation complète terminée. Tunnel actif sur ws://$DOMAIN:$PORT"
    echo "Logs: /var/log/proxy--ws.log et /var/log/proxy--ws.err"
    echo "Vérifie le status via: systemctl status proxy--ws"
}

main "$@"
