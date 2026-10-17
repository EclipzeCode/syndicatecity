"""Tiny JSON file server for syncing src/ into Studio without the Rojo plugin.

Serves GET /manifest -> [{"root": "ServerScriptService.Server", "path": ["Services", "JobService"],
"className": "ModuleScript", "source": "..."}]. Roots come from default.project.json, and file naming
follows Rojo's rules (*.server.luau -> Script, *.client.luau -> LocalScript, *.luau -> ModuleScript).

Run: python tools/devsync.py   (then run DevSync from the command bar, see src/tools/DevSync.luau)
"""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 34873


def project_roots():
    with open(os.path.join(ROOT, "default.project.json"), encoding="utf-8") as f:
        tree = json.load(f)["tree"]
    roots = []

    def walk(node, path):
        if "$path" in node:
            roots.append((".".join(path), os.path.join(ROOT, node["$path"])))
        for key, child in node.items():
            if not key.startswith("$") and isinstance(child, dict):
                walk(child, path + [key])

    walk(tree, [])
    return roots


def classify(filename):
    for suffix, class_name in ((".server.luau", "Script"), (".client.luau", "LocalScript"), (".luau", "ModuleScript")):
        if filename.endswith(suffix):
            return filename[: -len(suffix)], class_name
    return None, None


def manifest():
    entries = []
    for root_path, folder in project_roots():
        for dirpath, _, filenames in os.walk(folder):
            rel = os.path.relpath(dirpath, folder)
            parts = [] if rel == "." else rel.replace("\\", "/").split("/")
            for filename in sorted(filenames):
                name, class_name = classify(filename)
                if not name:
                    continue
                with open(os.path.join(dirpath, filename), encoding="utf-8") as f:
                    source = f.read()
                entries.append({"root": root_path, "path": parts + [name], "className": class_name, "source": source})
    return entries


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/manifest":
            self.send_error(404)
            return
        body = json.dumps(manifest()).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"devsync serving {ROOT} on http://localhost:{PORT}/manifest")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
