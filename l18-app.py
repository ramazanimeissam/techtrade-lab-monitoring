"""TechTrade Shop 2.0 - kleine Lab-Anwendung (PLAN-200 Lektion 18).

Neu gegenüber 1.4:
- Empfehlungen auf der Startseite: kostet pro Seitenaufruf Rechenzeit (RENDER_MS, CPU-Millisekunden)
- statische Dateien unter /static/ (Stylesheet, Logo) mit Cache-Control
- Header X-Backend: welche Instanz geantwortet hat (APP_NAME)
- Verbindungspool zur Datenbank (höchstens POOL_MAX Verbindungen pro Instanz)
"""
import datetime
import hashlib
import html
import os
import queue
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

import psycopg2

VERSION = os.environ.get("SHOP_VERSION", "2.0")
NAME = os.environ.get("APP_NAME", socket.gethostname())
PORT = int(os.environ.get("APP_PORT", "8080"))
RENDER_MS = float(os.environ.get("RENDER_MS", "14"))
POOL_MAX = int(os.environ.get("POOL_MAX", "10"))
DB = {
    "host": os.environ.get("DB_HOST", "db"),
    "port": int(os.environ.get("DB_PORT", "5432")),
    "user": os.environ.get("DB_USER", "shop"),
    "dbname": os.environ.get("DB_NAME", "shop"),
    "connect_timeout": 3,
    "options": "-c timezone=Europe/Zurich",
}
_pw_file = os.environ.get("DB_PASSWORD_FILE")
if _pw_file:
    with open(_pw_file, encoding="utf-8") as f:
        DB["password"] = f.read().strip()
else:
    DB["password"] = os.environ.get("DB_PASSWORD", "")

PRODUCTS = [
    ("NB-14", "Notebook 14 Zoll", 899),
    ("MON-27", "Monitor 27 Zoll", 329),
    ("DOCK-1", "USB-C-Dock", 149),
    ("KB-01", "Tastatur kabellos", 89),
    ("HS-10", "Headset mit Mikrofon", 119),
]

CSS = """/* TechTrade Shop - Stylesheet */
body { font-family: Arial, sans-serif; max-width: 760px; margin: 2em auto; color: #1f2937; }
header { display: flex; align-items: center; gap: 12px; border-bottom: 3px solid #1F3864; }
h1 { color: #1F3864; }
table { border-collapse: collapse; width: 100%; }
th { background: #1F3864; color: #fff; text-align: left; padding: 6px; }
td { padding: 6px; border-bottom: 1px solid #C2CBDA; }
tr:nth-child(even) td { background: #EAF1FB; }
.empf { background: #FDF0E3; padding: 8px 12px; border-left: 4px solid #D9822B; }
footer { color: #5A6478; font-size: 12px; margin-top: 2em; }
""" + "/* " + ("Reserve " * 400) + "*/\n"
LOGO = ("<svg xmlns='http://www.w3.org/2000/svg' width='48' height='48' viewBox='0 0 48 48'>"
        "<rect width='48' height='48' rx='8' fill='#1F3864'/>"
        "<text x='24' y='31' font-family='Arial' font-size='18' font-weight='bold' fill='#fff' "
        "text-anchor='middle'>TT</text></svg>\n")
STATIC = {
    "/static/shop.css": (CSS, "text/css; charset=utf-8"),
    "/static/logo.svg": (LOGO, "image/svg+xml"),
}


def log(msg):
    now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"{now} shop[{VERSION} {NAME}] {msg}", flush=True)


# ---------------------------------------------------------------- Rechenzeit pro Seitenaufruf
def _work(n):
    h = b"techtrade"
    for _ in range(n):
        h = hashlib.sha256(h).digest()
    return h


def _calibrate():
    """Anzahl Durchläufe für RENDER_MS CPU-Millisekunden (CPU-Zeit, unabhängig von der Drosselung)."""
    n = 20000
    t = time.process_time()
    _work(n)
    dt = time.process_time() - t
    return max(100, int(n * RENDER_MS / 1000 / dt)) if dt > 0 else 30000


ITER = _calibrate()


def recommendations(seed):
    h = _work(ITER + seed % 7)
    k = h[0] % len(PRODUCTS)
    return [PRODUCTS[k], PRODUCTS[(k + 2) % len(PRODUCTS)]]


# ---------------------------------------------------------------- Verbindungspool
_pool = queue.Queue()
_created = 0
_lock = threading.Lock()
_schema_ok = False


def _new_conn():
    global _schema_ok
    conn = psycopg2.connect(**DB)
    conn.autocommit = True
    if not _schema_ok:
        with conn.cursor() as cur:
            cur.execute(
                "CREATE TABLE IF NOT EXISTS bestellungen ("
                " id SERIAL PRIMARY KEY, artikel TEXT NOT NULL, menge INT NOT NULL,"
                " zeit TIMESTAMPTZ NOT NULL DEFAULT now())"
            )
            cur.execute("SELECT count(*) FROM bestellungen")
            if cur.fetchone()[0] == 0:
                cur.executemany(
                    "INSERT INTO bestellungen (artikel, menge) VALUES (%s, %s)",
                    [("NB-14", 2), ("MON-27", 5), ("DOCK-1", 3)],
                )
        _schema_ok = True
    return conn


def get_conn():
    global _created
    try:
        return _pool.get_nowait()
    except queue.Empty:
        pass
    with _lock:
        if _created < POOL_MAX:
            _created += 1
            try:
                return _new_conn()
            except Exception:
                _created -= 1
                raise
    return _pool.get(timeout=10)


def put_conn(conn, broken=False):
    global _created
    if broken:
        try:
            conn.close()
        except Exception:
            pass
        with _lock:
            _created -= 1
    else:
        _pool.put(conn)


def query(sql, args=None, fetch=True):
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, args)
            res = cur.fetchall() if fetch else None
    except Exception:
        put_conn(conn, broken=True)
        raise
    put_conn(conn)
    return res


# ---------------------------------------------------------------- HTTP
class Shop(BaseHTTPRequestHandler):
    server_version = "TechTradeShop/" + VERSION
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass                      # Zugriffe protokolliert der Reverse Proxy

    def _send(self, code, body, ctype="text/html; charset=utf-8", cache="no-store"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Backend", NAME)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in STATIC:
            body, ctype = STATIC[self.path]
            self._send(200, body, ctype, "public, max-age=3600")
            return
        if self.path == "/health":
            try:
                query("SELECT 1")
                self._send(200, "ok\n", "text/plain; charset=utf-8")
            except Exception as e:
                log(f"FEHLER Healthcheck: Datenbank nicht erreichbar: {e}".strip())
                self._send(503, "Datenbank nicht erreichbar\n", "text/plain; charset=utf-8")
            return
        if self.path not in ("/", "/index.html"):
            self._send(404, "<h1>404 - Seite nicht gefunden</h1>")
            return
        try:
            rows = query("SELECT artikel, menge, zeit FROM bestellungen ORDER BY id DESC LIMIT 5")
            total = query("SELECT count(*) FROM bestellungen")[0][0]
        except Exception as e:
            log(f"FEHLER: Datenbank nicht erreichbar: {e}".strip())
            self._send(500, "<h1>500 - Interner Fehler</h1><p>Bestellungen können nicht geladen werden.</p>")
            return
        empf = recommendations(total)
        prod = "".join(
            f"<tr><td>{a}</td><td>{html.escape(n)}</td><td>CHF {p}</td>"
            f"<td><form method='post' action='/bestellen'><input type='hidden' name='artikel' value='{a}'>"
            f"<input name='menge' value='1' size='2'> <button>Bestellen</button></form></td></tr>"
            for a, n, p in PRODUCTS
        )
        last = "".join(f"<li>{z:%d.%m.%Y %H:%M:%S} - {m} x {html.escape(a)}</li>" for a, m, z in rows)
        tipps = " und ".join(html.escape(n) for _, n, _ in empf)
        page = (
            "<!doctype html><html lang='de'><head><meta charset='utf-8'><title>TechTrade Shop</title>"
            "<link rel='stylesheet' href='/static/shop.css'></head><body>"
            "<header><img src='/static/logo.svg' alt='TechTrade' width='48' height='48'>"
            "<h1>TechTrade Shop</h1></header>"
            f"<p class='empf'>Für Sie empfohlen: {tipps}</p>"
            "<table><tr><th>Artikel</th><th>Bezeichnung</th><th>Preis</th><th></th></tr>"
            f"{prod}</table><h2>Bestellungen: {total}</h2><ul>{last}</ul>"
            f"<footer>Version {VERSION} · Instanz {html.escape(NAME)}</footer></body></html>"
        )
        self._send(200, page)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.send_header("X-Backend", NAME)
        self.end_headers()

    def do_POST(self):
        if self.path != "/bestellen":
            self._send(404, "<h1>404 - Seite nicht gefunden</h1>")
            return
        length = int(self.headers.get("Content-Length", "0"))
        form = parse_qs(self.rfile.read(length).decode("utf-8"))
        artikel = form.get("artikel", [""])[0]
        try:
            menge = int(form.get("menge", ["1"])[0])
        except ValueError:
            menge = 0
        if artikel not in {a for a, _, _ in PRODUCTS} or not 1 <= menge <= 99:
            self._send(400, "<h1>400 - Ungültige Bestellung</h1>")
            return
        try:
            query("INSERT INTO bestellungen (artikel, menge) VALUES (%s, %s)", (artikel, menge), fetch=False)
        except Exception as e:
            log(f"FEHLER: Bestellung nicht gespeichert: {e}".strip())
            self._send(500, "<h1>500 - Interner Fehler</h1><p>Bestellung nicht gespeichert.</p>")
            return
        log(f"Bestellung gespeichert: {menge} x {artikel}")
        self.send_response(303)
        self.send_header("Location", "/")
        self.send_header("Content-Length", "0")
        self.send_header("X-Backend", NAME)
        self.end_headers()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 256


if __name__ == "__main__":
    log(f"TechTrade Shop {VERSION} startet als {NAME} auf Port {PORT}, Datenbank {DB['host']}:{DB['port']}, "
        f"Rechenzeit pro Seite {RENDER_MS} ms ({ITER} Durchläufe)")
    try:
        Server(("0.0.0.0", PORT), Shop).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
