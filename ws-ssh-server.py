#!/usr/bin/env python3
"""
ws-ssh-server.py — WebSocket SSH Tunnel Server
Forwards SSH connections (port 22) via WebSocket proxy tunnel
Part of MAX PANEL SSH WS setup
"""

import argparse
import logging
import socket
import ssl
import sys
import threading
import time
from typing import Optional

# ══════════════════════════════════════════════════════════════════════════════
#  LOGGER SETUP
# ══════════════════════════════════════════════════════════════════════════════
logging.basicConfig(
    level=logging.INFO,
    format='[%(levelname)s] %(asctime)s — %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS — WebSocket Handshake
# ══════════════════════════════════════════════════════════════════════════════
def replace_placeholders(payload: str, target_host: str, target_port: int) -> bytes:
    """Replace [host] → target_host:port and [crlf] → \r\n"""
    host_value = f"{target_host}:{target_port}"
    payload = payload.replace("[host]", host_value).replace("[crlf]", "\r\n")
    return payload.encode()


def read_headers(sock: socket.socket, timeout: int = 10) -> bytes:
    """Read HTTP headers until blank line (\r\n\r\n)"""
    sock.settimeout(timeout)
    data = b""
    try:
        while b"\r\n\r\n" not in data:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        logger.warning("Timeout reading headers")
    return data


def establish_ws_tunnel(
    proxy_host: str,
    proxy_port: int,
    target_host: str,
    target_port: int,
    payload_template: str,
    use_tls: bool = False,
    sni_host: Optional[str] = None,
) -> Optional[socket.socket]:
    """
    Establish WebSocket tunnel to proxy server
    
    Parameters:
    - proxy_host/proxy_port: CDN/proxy endpoint
    - target_host/target_port: SSH server (usually localhost:22)
    - payload_template: HTTP upgrade request with [host] and [crlf] placeholders
    - use_tls: Wrap connection in SSL/TLS
    - sni_host: SNI hostname for TLS (if different from proxy_host)
    
    Returns: Connected socket ready for SSH, or None on failure
    """
    try:
        # 1. Connect to proxy
        logger.info(f"Connecting to proxy {proxy_host}:{proxy_port}...")
        sock = socket.create_connection((proxy_host, proxy_port), timeout=10)
        
        # 2. Optional TLS wrap
        if use_tls:
            logger.info(f"Wrapping connection in TLS (SNI: {sni_host or proxy_host})...")
            ctx = ssl.create_default_context()
            sock = ctx.wrap_socket(sock, server_hostname=(sni_host or proxy_host))
        
        # 3. Build & send payload
        logger.info(f"Sending WebSocket upgrade payload to {target_host}:{target_port}...")
        payload_bytes = replace_placeholders(payload_template, target_host, target_port)
        blocks = payload_bytes.split(b"\r\n\r\n")
        
        sock.sendall(blocks[0] + b"\r\n\r\n")
        
        # 4. Read response
        first_resp = read_headers(sock)
        first_text = first_resp.decode("latin1", errors="replace")
        
        if b"101" not in first_resp and b"100" not in first_resp:
            logger.warning(f"Unexpected response: {first_text[:100]}")
        
        # 5. Send remaining blocks if needed
        if b"100 Continue" in first_resp:
            for blk in blocks[1:]:
                if blk.strip():
                    sock.sendall(blk + b"\r\n\r\n")
            second_resp = read_headers(sock)
        else:
            for blk in blocks[1:]:
                if blk.strip():
                    sock.sendall(blk + b"\r\n\r\n")
        
        logger.info("✓ WebSocket tunnel established")
        return sock
    
    except Exception as e:
        logger.error(f"Failed to establish tunnel: {e}")
        return None


# ══════════════════════════════════════════════════════════════════════════════
#  TUNNEL RELAY — Forward data between client & tunnel
# ══════════════════════════════════════════════════════════════════════════════
def relay_data(src: socket.socket, dst: socket.socket, direction: str):
    """Forward data from src to dst"""
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            dst.sendall(data)
    except Exception as e:
        logger.debug(f"Relay {direction} ended: {e}")
    finally:
        src.close()
        dst.close()


def handle_client(client_sock: socket.socket, tunnel_sock: socket.socket):
    """Handle one client connection"""
    # Bi-directional relay
    t1 = threading.Thread(target=relay_data, args=(client_sock, tunnel_sock, "client→tunnel"))
    t2 = threading.Thread(target=relay_data, args=(tunnel_sock, client_sock, "tunnel→client"))
    t1.daemon = True
    t2.daemon = True
    t1.start()
    t2.start()
    t1.join()


# ══════════════════════════════════════════════════════════════════════════════
#  LOCAL LISTENER — Accept SSH clients on local port
# ══════════════════════════════════════════════════════════════════════════════
def start_listener(
    listen_host: str,
    listen_port: int,
    proxy_host: str,
    proxy_port: int,
    target_host: str,
    target_port: int,
    payload_template: str,
    use_tls: bool = False,
    sni_host: Optional[str] = None,
):
    """
    Start local SSH listener that tunnels each connection through WebSocket
    """
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_sock.bind((listen_host, listen_port))
    server_sock.listen(5)
    
    logger.info(f"Listening on {listen_host}:{listen_port} for SSH clients...")
    logger.info(f"Will forward to {proxy_host}:{proxy_port} → {target_host}:{target_port}")
    
    try:
        while True:
            client_sock, client_addr = server_sock.accept()
            logger.info(f"New client from {client_addr[0]}:{client_addr[1]}")
            
            # Establish tunnel for this client
            tunnel_sock = establish_ws_tunnel(
                proxy_host=proxy_host,
                proxy_port=proxy_port,
                target_host=target_host,
                target_port=target_port,
                payload_template=payload_template,
                use_tls=use_tls,
                sni_host=sni_host,
            )
            
            if tunnel_sock:
                # Handle client in background thread
                t = threading.Thread(target=handle_client, args=(client_sock, tunnel_sock))
                t.daemon = True
                t.start()
            else:
                logger.error("Failed to establish tunnel for this client")
                client_sock.close()
    
    except KeyboardInterrupt:
        logger.info("Shutting down...")
    finally:
        server_sock.close()


# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
def main():
    parser = argparse.ArgumentParser(
        description="WebSocket SSH Tunnel Server — forward SSH via WS proxy",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic HTTP payload (no TLS)
  python3 ws-ssh-server.py \\
    --listen 127.0.0.1:8880 \\
    --proxy domain.com:80 \\
    --target localhost:22 \\
    --payload 'GET /ws-ssh HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]'

  # HTTPS with SNI fronting
  python3 ws-ssh-server.py \\
    --listen 127.0.0.1:8880 \\
    --proxy cdn.com:443 \\
    --target localhost:22 \\
    --tls \\
    --sni domain.com \\
    --payload 'GET /ws-ssh HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]'
        """
    )
    
    parser.add_argument(
        "--listen",
        default="127.0.0.1:8880",
        help="Local address:port to listen on (default: 127.0.0.1:8880)"
    )
    parser.add_argument(
        "--proxy",
        required=True,
        help="Proxy server address:port (e.g., domain.com:80)"
    )
    parser.add_argument(
        "--target",
        default="localhost:22",
        help="Target SSH server (default: localhost:22)"
    )
    parser.add_argument(
        "--payload",
        default="GET /ws-ssh HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]",
        help="HTTP upgrade payload with [host] and [crlf] placeholders"
    )
    parser.add_argument(
        "--tls",
        action="store_true",
        help="Wrap proxy connection in TLS/SSL"
    )
    parser.add_argument(
        "--sni",
        help="SNI hostname for TLS (if different from proxy host)"
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable debug logging"
    )
    
    args = parser.parse_args()
    
    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Parse listen address
    listen_parts = args.listen.split(":")
    listen_host = listen_parts[0]
    listen_port = int(listen_parts[1]) if len(listen_parts) > 1 else 8880
    
    # Parse proxy address
    proxy_parts = args.proxy.split(":")
    proxy_host = proxy_parts[0]
    proxy_port = int(proxy_parts[1]) if len(proxy_parts) > 1 else (443 if args.tls else 80)
    
    # Parse target address
    target_parts = args.target.split(":")
    target_host = target_parts[0]
    target_port = int(target_parts[1]) if len(target_parts) > 1 else 22
    
    logger.info("="*70)
    logger.info("  WebSocket SSH Tunnel Server — MAX PANEL")
    logger.info("="*70)
    logger.info(f"  Listen      : {listen_host}:{listen_port}")
    logger.info(f"  Proxy       : {proxy_host}:{proxy_port} (TLS: {args.tls})")
    logger.info(f"  Target SSH  : {target_host}:{target_port}")
    logger.info(f"  SNI Host    : {args.sni or 'auto'}")
    logger.info("="*70)
    
    start_listener(
        listen_host=listen_host,
        listen_port=listen_port,
        proxy_host=proxy_host,
        proxy_port=proxy_port,
        target_host=target_host,
        target_port=target_port,
        payload_template=args.payload,
        use_tls=args.tls,
        sni_host=args.sni,
    )


if __name__ == "__main__":
    main()
