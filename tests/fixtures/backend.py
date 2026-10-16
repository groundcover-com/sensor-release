"""Local HTTPS destination for installer acceptance tests; no tenant is used."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ssl


class Backend(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health/live' and not self.headers.get('apikey'):
            self.send_error(401)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{}')

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.send_response(200)
        self.end_headers()


server = ThreadingHTTPServer(('0.0.0.0', 443), Backend)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain('/fixtures/cert.pem', '/fixtures/key.pem')
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
