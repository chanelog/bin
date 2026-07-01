#!/bin/bash
# ============================================================
#  ALL-IN-ONE INSTALLER — SSHWS & XRAY TUNNELING PANEL
#  Semua binary diambil dari: https://github.com/chanelog/bin
#  Jalankan: chmod +x setup.sh && ./setup.sh
# ============================================================
export DEBIAN_FRONTEND=noninteractive

R="\e[31m"; G="\e[32m"; Y="\e[33m"; C="\e[36m"; N="\e[0m"
info(){ echo -e "${C}[INFO]${N} $1"; }
ok(){ echo -e "${G}[ OK ]${N} $1"; }
err(){ echo -e "${R}[ERR ]${N} $1"; }

[ "$EUID" -ne 0 ] && { err "Harus dijalankan sebagai root"; exit 1; }

REPO="https://raw.githubusercontent.com/chanelog/bin/main"
XDIR="/etc/xray"; TDIR="/etc/tunnel"; BIN="/usr/local/bin"; SRC="/root/bin-src"
mkdir -p "$XDIR" "$TDIR/ssh" "$BIN" "$SRC" /var/log/xray /var/www/html

# ---------- 1. Domain ----------
read -rp "Masukkan domain (sudah pointing ke IP VPS): " DOMAIN
[ -z "$DOMAIN" ] && { err "Domain kosong"; exit 1; }
echo "$DOMAIN" > "$XDIR/domain"
ok "Domain: $DOMAIN"

# ---------- 2. Dependencies ----------
info "Install dependency dasar..."
apt update -y
apt install -y curl wget unzip tar socat cron python3 net-tools iptables \
  ca-certificates gnupg lsb-release build-essential libpcre3 libpcre3-dev \
  libssl-dev zlib1g-dev stunnel4 dropbear fail2ban vnstat htop tmux || true

# ---------- 3. Unduh semua bin dari repo ----------
info "Mengunduh semua binary dari repo chanelog/bin..."
cd "$SRC"
for f in acme.sh jq-linux-amd64 ws ws_tunnel.py ohpserver udpgw \
         ssh-ws.dropbear ssh-ws.openssh install-release.sh ws.service.txt \
         Xray-linux-64.zip trojan-go-linux-amd64.zip badvpn-master.zip \
         stunnel-master.zip dropbear-master.zip openssh-portable-master.zip \
         fail2ban-master.zip vnstat-master.zip htop-main.zip tmux-master.zip \
         handy-sshd-0.4.2-linux-amd64.deb nginx-1.28.0.tar.gz bin.zip; do
  wget -q "$REPO/$f" -O "$f" && ok "unduh $f" || err "gagal unduh $f (lanjut)"
done
install -m 755 jq-linux-amd64 "$BIN/jq" 2>/dev/null || true

# ---------- 4. Xray core ----------
info "Memasang Xray-core..."
unzip -o Xray-linux-64.zip -d /tmp/xray >/dev/null 2>&1 || true
[ -f /tmp/xray/xray ] && install -m 755 /tmp/xray/xray "$BIN/xray"
[ -f /tmp/xray/geoip.dat ] && cp /tmp/xray/geoip.dat "$XDIR/"
[ -f /tmp/xray/geosite.dat ] && cp /tmp/xray/geosite.dat "$XDIR/"

# ---------- 5. Trojan-Go, badvpn, ohp ----------
unzip -o trojan-go-linux-amd64.zip -d /tmp/tg >/dev/null 2>&1 || true
[ -f /tmp/tg/trojan-go ] && install -m 755 /tmp/tg/trojan-go "$BIN/trojan-go"
install -m 755 udpgw "$BIN/badvpn-udpgw" 2>/dev/null || true
install -m 755 ohpserver "$BIN/ohpserver" 2>/dev/null || true

# ---------- 6. nginx (compile dari tarball repo) ----------
if ! command -v nginx >/dev/null 2>&1; then
  info "Compile nginx dari nginx-1.28.0.tar.gz..."
  tar xzf nginx-1.28.0.tar.gz
  cd nginx-1.28.0
  ./configure --prefix=/etc/nginx --sbin-path=/usr/sbin/nginx \
    --conf-path=/etc/nginx/nginx.conf --pid-path=/run/nginx.pid \
    --with-http_ssl_module --with-http_v2_module --with-http_realip_module
  make -j"$(nproc)" && make install
  cd "$SRC"
fi
mkdir -p /etc/nginx/conf.d /var/log/nginx

# ---------- 7. Engine SSHWS ----------
cat > "$BIN/ws-ssh.py" <<'WSEOF'
#!/usr/bin/python3
import socket, threading, select, time

LISTEN_ADDR = '127.0.0.1'
LISTEN_PORT = 8880
BUFLEN      = 4096 * 4
TIMEOUT     = 60
TARGET      = '127.0.0.1:143'
RESPONSE    = 'HTTP/1.1 101 Switching Protocols\r\n\r\n'

class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.host = host; self.port = port; self.running = False
        self.threads = []; self.lock = threading.Lock()
    def run(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((self.host, self.port)); self.sock.listen(0)
        self.running = True
        while self.running:
            try:
                c, addr = self.sock.accept(); c.setblocking(1)
            except socket.timeout:
                continue
            conn = ConnHandler(c, self)
            conn.start(); self.addConn(conn)
    def addConn(self, conn):
        with self.lock:
            if self.running: self.threads.append(conn)
    def removeConn(self, conn):
        with self.lock:
            if conn in self.threads: self.threads.remove(conn)
    def close(self):
        self.running = False
        with self.lock:
            for c in self.threads: c.close()

class ConnHandler(threading.Thread):
    def __init__(self, sock, server):
        threading.Thread.__init__(self)
        self.client = sock; self.server = server
        self.clientClosed = False; self.targetClosed = True
    def close(self):
        try:
            if not self.clientClosed: self.client.shutdown(socket.SHUT_RDWR); self.client.close()
        except: pass
        self.clientClosed = True
        try:
            if not self.targetClosed: self.target.shutdown(socket.SHUT_RDWR); self.target.close()
        except: pass
        self.targetClosed = True
    def run(self):
        try:
            self.client.recv(BUFLEN)
            host, port = TARGET.split(':')
            self.target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.target.connect((host, int(port))); self.targetClosed = False
            self.client.sendall(RESPONSE.encode())
            self.doCONNECT()
        except Exception:
            pass
        finally:
            self.close(); self.server.removeConn(self)
    def doCONNECT(self):
        socs = [self.client, self.target]; count = 0
        while True:
            count += 1
            recv, _, error = select.select(socs, [], socs, 3)
            if error: break
            if recv:
                for s in recv:
                    try:
                        data = s.recv(BUFLEN)
                        if data:
                            (self.target if s is self.client else self.client).sendall(data)
                            count = 0
                        else:
                            break
                    except: break
            if count == TIMEOUT: break

def main():
    server = Server(LISTEN_ADDR, LISTEN_PORT); server.start()
    print('SSH-WS proxy %s:%d -> %s' % (LISTEN_ADDR, LISTEN_PORT, TARGET))
    try:
        while True: time.sleep(1)
    except KeyboardInterrupt:
        server.close()

if __name__ == '__main__':
    main()
WSEOF
chmod +x "$BIN/ws-ssh.py"

cat > /etc/systemd/system/ws-ssh.service <<'SVCEOF'
[Unit]
Description=SSH WebSocket Proxy
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-ssh.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SVCEOF

# ---------- 8. Xray config + service ----------
cat > "$XDIR/config.json" <<'XRAYEOF'
{
  "log": { "loglevel": "warning", "access": "/var/log/xray/access.log" },
  "inbounds": [
    {
      "listen": "127.0.0.1", "port": 10001, "protocol": "vmess",
      "settings": { "clients": [] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess" } }
    },
    {
      "listen": "127.0.0.1", "port": 10002, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless" } }
    },
    {
      "listen": "127.0.0.1", "port": 10003, "protocol": "trojan",
      "settings": { "clients": [] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
XRAYEOF

cat > /etc/systemd/system/xray.service <<'XSVCEOF'
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=always
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
XSVCEOF

# ---------- 9. acme.sh: sertifikat ----------
info "Menerbitkan sertifikat via acme.sh (standalone)..."
chmod +x "$SRC/acme.sh"
systemctl stop nginx 2>/dev/null || true
"$SRC/acme.sh" --install --home /root/.acme.sh --accountemail "admin@$DOMAIN" || true
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force
/root/.acme.sh/acme.sh --installcert -d "$DOMAIN" --ecc \
  --fullchain-file "$XDIR/xray.crt" --key-file "$XDIR/xray.key"
chmod 600 "$XDIR/xray.key"

# ---------- 10. nginx config ----------
cat > /etc/nginx/nginx.conf <<'NGXMAIN'
user root;
worker_processes auto;
events { worker_connections 1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    include /etc/nginx/conf.d/*.conf;
}
NGXMAIN

cat > /etc/nginx/conf.d/tunnel.conf <<'NGINXEOF'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {
    listen 80;
    listen 443 ssl http2;
    server_name DOMAIN_PLACEHOLDER;

    ssl_certificate     /etc/xray/xray.crt;
    ssl_certificate_key /etc/xray/xray.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/html;
    index index.html;

    location /sshws {
        proxy_pass http://127.0.0.1:8880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_read_timeout 7d;
    }
    location /vmess {
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
    }
    location /vless {
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
    }
    location /trojan {
        proxy_pass http://127.0.0.1:10003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
    }
}
NGINXEOF
sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" /etc/nginx/conf.d/tunnel.conf
echo "<h1>OK</h1>" > /var/www/html/index.html

cat > /etc/systemd/system/nginx.service <<'NGXSVC'
[Unit]
Description=nginx
After=network.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/usr/sbin/nginx -s reload
ExecStop=/usr/sbin/nginx -s quit
Restart=always

[Install]
WantedBy=multi-user.target
NGXSVC

# ---------- 11. Dropbear ----------
sed -i 's/^NO_START=1/NO_START=0/' /etc/default/dropbear 2>/dev/null || true
sed -i 's/^DROPBEAR_PORT=.*/DROPBEAR_PORT=143/' /etc/default/dropbear 2>/dev/null || true
grep -q "/bin/false" /etc/shells || echo "/bin/false" >> /etc/shells

# ---------- 12. Menu CLI ----------
cat > "$BIN/menu" <<'MENUEOF'
#!/bin/bash
R="\e[31m"; G="\e[32m"; Y="\e[33m"; C="\e[36m"; W="\e[97m"; N="\e[0m"
DOMAIN=$(cat /etc/xray/domain 2>/dev/null)
IP=$(curl -s ipv4.icanhazip.com)
line(){ echo -e "${C}=====================================================${N}"; }
header(){
  clear; line
  echo -e "        ${W}TUNNELING PANEL — SSHWS & XRAY${N}"
  echo -e "        Domain : ${G}$DOMAIN${N}"
  echo -e "        IP VPS : ${G}$IP${N}"
  line
}
pause(){ echo; read -rp "  Tekan ENTER untuk kembali..." x; mainmenu; }

mainmenu(){
  header
  echo -e "  ${Y}[1]${N} Menu SSH / SSHWS"
  echo -e "  ${Y}[2]${N} Menu VMESS"
  echo -e "  ${Y}[3]${N} Menu VLESS"
  echo -e "  ${Y}[4]${N} Menu TROJAN"
  echo -e "  ${Y}[5]${N} System"
  echo -e "  ${Y}[6]${N} Monitoring"
  echo -e "  ${Y}[0]${N} Keluar"
  line
  read -rp "  Pilih menu : " opt
  case $opt in
    1) menu_ssh ;;
    2) menu_xray vmess /vmess ;;
    3) menu_xray vless /vless ;;
    4) menu_xray trojan /trojan ;;
    5) menu_sys ;; 6) menu_mon ;; 0) exit 0 ;; *) mainmenu ;;
  esac
}

menu_ssh(){
  header
  echo -e "  ${Y}[1]${N} Buat akun SSH (auto payload SSHWS NTLS)"
  echo -e "  ${Y}[2]${N} Hapus akun SSH"
  echo -e "  ${Y}[3]${N} List member"
  echo -e "  ${Y}[0]${N} Kembali"
  line; read -rp "  Pilih : " o
  case $o in
    1) add_ssh ;;
    2) header; read -rp "  Username : " u; userdel -f "$u" 2>/dev/null; rm -f /etc/tunnel/ssh/$u.txt; echo "  User dihapus"; pause ;;
    3) awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd; pause ;;
    0) mainmenu ;; *) menu_ssh ;;
  esac
}

add_ssh(){
  header
  read -rp "  Username : " user
  read -rp "  Password : " pass
  read -rp "  Masa aktif (hari) : " days
  exp=$(date -d "$days days" +%Y-%m-%d)
  useradd -e "$exp" -s /bin/false -M "$user" 2>/dev/null
  echo -e "$pass\n$pass" | passwd "$user" >/dev/null 2>&1
  clear; line
  echo -e "  ${G}AKUN SSH BERHASIL DIBUAT${N}"; line
  echo -e "  Domain   : ${W}$DOMAIN${N}"
  echo -e "  IP VPS   : ${W}$IP${N}"
  echo -e "  Username : ${W}$user${N}"
  echo -e "  Password : ${W}$pass${N}"
  echo -e "  Expired  : ${W}$exp${N}"
  echo -e "  OpenSSH 22 | Dropbear 143,109 | SSL 445,777"
  echo -e "  SSHWS 80 (NTLS) / 443 (TLS)  path /sshws"
  line
  echo -e "  ${Y}PAYLOAD SSHWS NTLS (port 80):${N}"
  echo -e "${W}GET /sshws HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]${N}"
  echo
  echo -e "  ${Y}PAYLOAD SSHWS NTLS (bug host / CDN):${N}"
  echo -e "${W}GET / HTTP/1.1[crlf]Host: [bug.com][crlf]X-Online-Host: ${DOMAIN}[crlf]X-Forward-Host: ${DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]${N}"
  echo
  echo -e "  ${Y}PAYLOAD SSHWS TLS (port 443, SNI):${N}"
  echo -e "${W}GET wss://${DOMAIN}/sshws HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]${N}"
  line
  { echo "user=$user pass=$pass exp=$exp"; echo "payload_ntls=GET /sshws HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"; } > /etc/tunnel/ssh/$user.txt
  pause
}

# menu_xray <proto> <path>
menu_xray(){
  proto=$1; path=$2
  header
  echo -e "  ${Y}[1]${N} Buat akun ${proto^^}   ${Y}[2]${N} Hapus akun ${proto^^}   ${Y}[0]${N} Kembali"
  line; read -rp "  Pilih : " o
  case $o in
    1) add_xray "$proto" "$path" ;;
    2) header; read -rp "  Remark yang dihapus : " em
       cfg=/etc/xray/config.json
       jq --arg em "$em" '(.inbounds[].settings.clients) |= map(select(.email != $em))' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
       systemctl restart xray; echo "  Akun dihapus"; pause ;;
    0) mainmenu ;; *) menu_xray "$proto" "$path" ;;
  esac
}

add_xray(){
  proto=$1; path=$2
  header
  read -rp "  Remark / nama : " nm
  read -rp "  Masa aktif (hari) : " days
  exp=$(date -d "$days days" +%Y-%m-%d)
  uuid=$(cat /proc/sys/kernel/random/uuid)
  cfg=/etc/xray/config.json
  if [ "$proto" = "trojan" ]; then
    jq --arg id "$uuid" --arg em "$nm" --arg p "$path" '(.inbounds[] | select(.streamSettings.wsSettings.path == $p).settings.clients) += [{"password":$id,"email":$em}]' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  elif [ "$proto" = "vless" ]; then
    jq --arg id "$uuid" --arg em "$nm" --arg p "$path" '(.inbounds[] | select(.streamSettings.wsSettings.path == $p).settings.clients) += [{"id":$id,"email":$em}]' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  else
    jq --arg id "$uuid" --arg em "$nm" --arg p "$path" '(.inbounds[] | select(.streamSettings.wsSettings.path == $p).settings.clients) += [{"id":$id,"alterId":0,"email":$em}]' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  fi
  systemctl restart xray
  clear; line
  echo -e "  ${G}AKUN ${proto^^} BERHASIL DIBUAT${N}"; line
  echo -e "  Remark    : ${W}$nm${N}"
  echo -e "  Domain    : ${W}$DOMAIN${N}"
  echo -e "  UUID/Pass : ${W}$uuid${N}"
  echo -e "  Path      : ${W}$path${N}"
  echo -e "  Network ws | TLS 443 | NTLS 80"
  echo -e "  Expired   : ${W}$exp${N}"; line
  if [ "$proto" = "vmess" ]; then
    raw='{"v":"2","ps":"'"$nm"'","add":"'"$DOMAIN"'","port":"443","id":"'"$uuid"'","aid":"0","net":"ws","path":"'"$path"'","host":"'"$DOMAIN"'","tls":"tls"}'
    echo -e "  ${Y}vmess://$(echo -n "$raw" | base64 -w0)${N}"
  elif [ "$proto" = "vless" ]; then
    echo -e "  ${Y}TLS :${N} vless://$uuid@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=$path#$nm"
    echo -e "  ${Y}NTLS:${N} vless://$uuid@$DOMAIN:80?encryption=none&security=none&type=ws&host=$DOMAIN&path=$path#$nm"
  else
    echo -e "  ${Y}TLS :${N} trojan://$uuid@$DOMAIN:443?security=tls&type=ws&host=$DOMAIN&path=$path#$nm"
  fi
  line; pause
}

menu_sys(){
  header
  echo -e "  ${Y}[1]${N} Restart semua service"
  echo -e "  ${Y}[2]${N} Renew sertifikat (acme.sh)"
  echo -e "  ${Y}[3]${N} Ganti domain"
  echo -e "  ${Y}[4]${N} Backup config"
  echo -e "  ${Y}[0]${N} Kembali"
  line; read -rp "  Pilih : " o
  case $o in
    1) systemctl restart nginx xray ws-ssh dropbear stunnel4 2>/dev/null; echo "  OK"; pause ;;
    2) /root/.acme.sh/acme.sh --renew -d "$DOMAIN" --ecc --force; systemctl restart nginx xray; pause ;;
    3) read -rp "  Domain baru : " nd; echo "$nd" > /etc/xray/domain; sed -i "s/$DOMAIN/$nd/g" /etc/nginx/conf.d/tunnel.conf; systemctl restart nginx; pause ;;
    4) tar czf /root/backup-$(date +%F).tar.gz /etc/xray /etc/nginx/conf.d /etc/tunnel; echo "  Backup di /root"; pause ;;
    0) mainmenu ;; *) menu_sys ;;
  esac
}

menu_mon(){
  header
  echo -e "  ${Y}[1]${N} vnstat   ${Y}[2]${N} htop   ${Y}[3]${N} Status service   ${Y}[0]${N} Kembali"
  line; read -rp "  Pilih : " o
  case $o in
    1) vnstat; pause ;; 2) htop ;;
    3) for s in nginx xray ws-ssh dropbear stunnel4; do printf "  %-12s : " "$s"; systemctl is-active "$s" 2>/dev/null; done; pause ;;
    0) mainmenu ;; *) menu_mon ;;
  esac
}

mainmenu
MENUEOF
chmod +x "$BIN/menu"
ln -sf "$BIN/menu" /usr/bin/menu

# ---------- 13. Aktifkan service ----------
systemctl daemon-reload
for s in nginx xray ws-ssh dropbear stunnel4; do systemctl enable --now "$s" 2>/dev/null || true; done

ok "INSTALASI SELESAI. Ketik: menu"