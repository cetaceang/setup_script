#!/usr/bin/env python3
"""Invoked only by test_stream inside sudo unshare -n; no production access."""
import http.server
import socket
import ssl
import subprocess
import sys
import threading
import time
from pathlib import Path


def main():
    root, binary = Path(sys.argv[1]), sys.argv[2]
    mode = sys.argv[3] if len(sys.argv) > 3 else 'full'
    subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True)
    certificate = root / 'letsencrypt/live/example.com/fullchain.pem'
    key = root / 'letsencrypt/live/example.com/privkey.pem'
    servers = []
    backends = ((443, b'existing-listener', True),) if mode == 'local-only' else (
        (3000, b'website', False), (34138, b'node-one', True), (39149, b'node-two', True))
    for port, label, tls in backends:
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def do_GET(self):
                if self.headers.get('Upgrade', '').lower() == 'websocket':
                    self.send_response(101)
                    self.send_header('Upgrade', 'websocket')
                    self.send_header('Connection', 'Upgrade')
                    self.end_headers()
                    self.close_connection = True
                else:
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(self.server.label)))
                    self.end_headers()
                    self.wfile.write(self.server.label)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler)
        server.label = label
        if tls:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certificate, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
    challenge = root / 'acme/.well-known/acme-challenge/test-token'
    challenge.parent.mkdir(parents=True, exist_ok=True)
    challenge.write_text('acme-ok')
    context = ssl.create_default_context(cafile=str(certificate))

    def request(domain, port=443, path='/', upgrade=False):
        raw = socket.create_connection(('127.0.0.1', port), timeout=3)
        connection = raw if port == 80 else context.wrap_socket(raw, server_hostname=domain)
        with connection:
            headers = f'GET {path} HTTP/1.1\r\nHost: {domain}\r\n'
            headers += 'Connection: Upgrade\r\nUpgrade: websocket\r\n' if upgrade else 'Connection: close\r\n'
            connection.sendall((headers + '\r\n').encode())
            result = b''
            while True:
                chunk = connection.recv(65536)
                if not chunk:
                    return result
                result += chunk
                if upgrade and b'\r\n\r\n' in result:
                    return result

    with (root / 'live-nginx.log').open('wb') as log:
        process = subprocess.Popen([binary, '-p', str(root / 'nginx') + '/', '-e', 'stderr',
                                    '-c', str(root / 'nginx/nginx.conf'), '-g', 'daemon off;'], stdout=log, stderr=log)
        try:
            for _ in range(60):
                if process.poll() is not None:
                    raise AssertionError((root / 'live-nginx.log').read_text())
                try:
                    if mode == 'local-only':
                        result = request('node1.example.com', 8443)
                    elif mode == 'relay':
                        result = request('node1.example.com')
                    else:
                        result = request('blog.example.com')
                    break
                except (OSError, ssl.SSLError):
                    time.sleep(0.05)
            else:
                raise AssertionError('Nginx did not become ready')
            if mode == 'local-only':
                assert b'Welcome' in result, result
                assert b'existing-listener' in request('node1.example.com'), 'public 443 changed'
                context.set_alpn_protocols(['h2'])
                with context.wrap_socket(socket.create_connection(('127.0.0.1', 8443), timeout=3), server_hostname='node1.example.com') as connection:
                    assert connection.selected_alpn_protocol() == 'h2'
                try:
                    request('unrelated.other.net', 8443)
                except ssl.SSLCertVerificationError:
                    pass
                else:
                    raise AssertionError('certificate must not cover an unrelated domain')
            else:
                assert b'node-one' in request('node1.example.com')
                assert b'node-two' in request('node2.example.com')
                if mode == 'relay':
                    for port in (80, 8443):
                        try:
                            connection = socket.create_connection(('127.0.0.1', port), timeout=1)
                        except ConnectionRefusedError:
                            pass
                        else:
                            connection.close()
                            raise AssertionError(f'pure relay unexpectedly listens on {port}')
                    try:
                        request('unknown.example.com')
                    except (OSError, ssl.SSLError):
                        pass
                    else:
                        raise AssertionError('unknown SNI must not be routed to a node')
                else:
                    assert b'website' in result, result
                    assert b'website' in request('unknown.example.com')
                    assert b'Welcome' in request('node1.example.com', 8443)
                    redirect = request('blog.example.com', 80)
                    assert b'308' in redirect and b'https://blog.example.com/' in redirect, redirect
                    assert b'acme-ok' in request('blog.example.com', 80, '/.well-known/acme-challenge/test-token')
                    assert b'101' in request('blog.example.com', path='/ws', upgrade=True)
                    context.set_alpn_protocols(['h2'])
                    with context.wrap_socket(socket.create_connection(('127.0.0.1', 443), timeout=3), server_hostname='blog.example.com') as connection:
                        assert connection.selected_alpn_protocol() == 'h2'
        finally:
            process.terminate()
            process.wait(timeout=5)
            for server in servers:
                server.shutdown()
    print(f'Live namespace smoke passed ({mode}): TLS/SNI, certificate verification and expected listeners')


if __name__ == '__main__':
    main()
