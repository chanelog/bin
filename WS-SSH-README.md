# WebSocket SSH Tunnel — MAX PANEL Setup

Paket ini berisi 2 file Python untuk tunnel SSH via WebSocket (SSH WS).

## 📦 File

| File | Fungsi |
|------|--------|
| **ws_tunnel.py** | Module core — WebSocket handshake & TLS support |
| **ws-ssh-server.py** | Server wrapper — listen lokal & relay SSH via WS |

---

## 🚀 Cara Kerja

```
[SSH Client] ─→ [ws-ssh-server] ─→ [WebSocket Tunnel] ─→ [Proxy/CDN] ─→ [SSH Server:22]
  localhost:8880                    HTTP/HTTPS Payload              domain.com
```

---

## 📋 Requirement

- **Python 3.6+**
- **No external dependencies** — pakai standard library saja (socket, ssl, threading, argparse)

---

## 🔧 Instalasi

### Opsi A — Upload ke chanelog/bin (Recommended)

```bash
# Di local machine
git clone https://github.com/chanelog/bin
cd bin

# Copy file
cp ws_tunnel.py chanelog/bin/
cp ws-ssh-server.py chanelog/bin/
chmod +x ws-ssh-server.py

# Push ke repo
git add ws_tunnel.py ws-ssh-server.py
git commit -m "Add WebSocket SSH tunnel support"
git push
```

### Opsi B — Install lokal di VPS

```bash
# Copy ke VPS
scp ws_tunnel.py ws-ssh-server.py root@vpn.example.com:/usr/local/bin/

# atau
cat > /usr/local/bin/ws_tunnel.py << 'EOF'
[paste isi ws_tunnel.py]
EOF

cat > /usr/local/bin/ws-ssh-server.py << 'EOF'
[paste isi ws-ssh-server.py]
EOF

chmod +x /usr/local/bin/ws-ssh-server.py
```

---

## 🎯 Penggunaan

### Mode 1 — HTTP WebSocket (Port 80, no TLS)

```bash
python3 /usr/local/bin/ws-ssh-server.py \
  --listen 127.0.0.1:8880 \
  --proxy vpn.example.com:80 \
  --target localhost:22 \
  --payload 'GET /ws-ssh HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]'
```

**Client SSH:**
```bash
ssh -p 8880 username@localhost
```

---

### Mode 2 — HTTPS WebSocket TLS (Port 443)

```bash
python3 /usr/local/bin/ws-ssh-server.py \
  --listen 127.0.0.1:8880 \
  --proxy vpn.example.com:443 \
  --target localhost:22 \
  --tls \
  --sni vpn.example.com \
  --payload 'GET /ws-ssh HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]'
```

---

### Mode 3 — SNI Fronting (Domain Spoofing)

```bash
python3 /usr/local/bin/ws-ssh-server.py \
  --listen 127.0.0.1:8880 \
  --proxy cdn.cloudflare.com:443 \
  --target localhost:22 \
  --tls \
  --sni vpn.example.com \
  --payload 'GET /ws-ssh HTTP/1.1[crlf]Host: vpn.example.com[crlf]Upgrade: websocket[crlf][crlf]'
```

---

### Mode 4 — HTTP Injector Payload (Untuk Aplikasi Indonesia)

```bash
python3 /usr/local/bin/ws-ssh-server.py \
  --listen 127.0.0.1:8880 \
  --proxy 1.1.1.1:80 \
  --target localhost:22 \
  --payload 'CONNECT [host] HTTP/1.1[crlf]Host: 1.1.1.1[crlf][crlf]'
```

---

### Mode 5 — Debug Mode

```bash
python3 /usr/local/bin/ws-ssh-server.py \
  --listen 127.0.0.1:8880 \
  --proxy vpn.example.com:80 \
  --target localhost:22 \
  --debug
```

Output:
```
[INFO] WebSocket SSH Tunnel Server — MAX PANEL
[INFO] Listen      : 127.0.0.1:8880
[INFO] Proxy       : vpn.example.com:80 (TLS: False)
[INFO] Target SSH  : localhost:22
[INFO] SNI Host    : auto
[DEBUG] New client from 192.168.1.100:54321
[DEBUG] Connecting to proxy vpn.example.com:80...
[INFO] ✓ WebSocket tunnel established
```

---

## 🔌 Integrasi dengan setup-max.sh

Script ini sudah siap integrate ke `setup-max.sh`. Fitur:

1. **Auto-install** — Download dari chanelog/bin saat install
2. **Systemd service** — Auto-start `/etc/systemd/system/ws-ssh-proxy.service`
3. **Config otomatis** — Generate payload sesuai domain & port
4. **Nginx routing** — Path `/ws-ssh` → forward ke localhost:8880

---

## 📝 Nginx Configuration (jika manual)

```nginx
server {
    listen 80;
    listen 443 ssl http2;
    server_name vpn.example.com;

    ssl_certificate /etc/ssl/maxpanel/vpn.example.com/fullchain.pem;
    ssl_certificate_key /etc/ssl/maxpanel/vpn.example.com/key.pem;

    # WebSocket SSH proxy
    location /ws-ssh {
        proxy_pass http://127.0.0.1:8880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 86400;
    }
}
```

---

## 🎮 Payload Examples

### HTTP Injector (Mode TUNNEL / DIRECT)
```
GET / HTTP/1.1[crlf]
Host: [host][crlf]
Upgrade: websocket[crlf]
Connection: Upgrade[crlf]
[crlf]
```

### HTTP Custom (OpenTunnel / KPN Tunnel)
```
CONNECT [host] HTTP/1.1[crlf]
Host: 1.1.1.1[crlf]
[crlf]
```

### HTTPS / SNI Fronting
```
GET /ws-ssh HTTP/1.1[crlf]
Host: [host][crlf]
User-Agent: Mozilla/5.0[crlf]
Upgrade: websocket[crlf]
Connection: Upgrade[crlf]
[crlf]
```

---

## ⚠️ Troubleshooting

### "Connection refused" saat connect
- **Sebab**: ws-ssh-server belum running atau listen port salah
- **Solusi**: Pastikan `python3 ws-ssh-server.py` jalan di VPS

### "WebSocket handshake failed"
- **Sebab**: Proxy server tidak support WebSocket atau payload salah
- **Solusi**: Cek payload format & pastikan proxy forward dengan benar

### "Port already in use"
- **Sebab**: Port 8880 sudah dipakai service lain
- **Solusi**: Gunakan port lain: `--listen 127.0.0.1:9999`

### SSL Certificate Error
- **Sebab**: SNI domain tidak match dengan cert
- **Solusi**: Gunakan `--sni` yang sesuai dengan certificate domain

---

## 📦 Upload ke chanelog/bin

**Langkah-langkah:**

1. **Clone repo**
```bash
git clone https://github.com/chanelog/bin
cd bin
```

2. **Copy file**
```bash
cp ws_tunnel.py .
cp ws-ssh-server.py .
chmod +x ws-ssh-server.py
```

3. **Commit & Push**
```bash
git add ws_tunnel.py ws-ssh-server.py
git commit -m "Add WebSocket SSH tunnel (ws_tunnel.py & ws-ssh-server.py)"
git push origin main
```

4. **Update script setup-max.sh**
```bash
# Di setup-max.sh, tambahkan:
WS_TUNNEL_URL="${BIN_REPO}/ws_tunnel.py"
WS_SSH_SERVER_URL="${BIN_REPO}/ws-ssh-server.py"
```

---

## 📄 License

Open source — Bebas dimodifikasi & dipublikasi

---

**Created for MAX PANEL SSH WebSocket Support** ✨
