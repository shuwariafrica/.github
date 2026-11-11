"""A stand-in HTTPS proxy for api-commit's tests. It answers CONNECT itself, ends TLS with the
certificate it is given, and appends each request line and Authorization header it then reads to
<log>; it connects nowhere. Its port is written to <port file>.

Usage: python3 -I proxy.py <port file> <log> <certificate> <key>
"""

import socket
import ssl
import sys
import threading


def head(connection):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = connection.recv(4096)
        if not chunk:
            break
        data += chunk
    return data


def serve(connection, context, log):
    try:
        if not head(connection).startswith(b"CONNECT "):
            return
        connection.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        tunnel = context.wrap_socket(connection, server_side=True)
        lines = head(tunnel).split(b"\r\n")
        with open(log, "ab") as file:
            for line in lines:
                if line[:4] in (b"GET ", b"POST") or line.lower().startswith(b"authorization"):
                    file.write(line + b"\n")
        tunnel.sendall(b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        tunnel.close()
    except (OSError, ssl.SSLError):
        pass
    finally:
        connection.close()


def main():
    port_file, log, certificate, key = sys.argv[1:5]
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(16)
    with open(port_file, "w", encoding="ascii") as file:
        file.write(str(listener.getsockname()[1]))
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=serve, args=(connection, context, log), daemon=True).start()


main()
