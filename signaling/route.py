import json
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ADMIN = "http://127.0.0.1:2019"
ROUTE = {
    "@id": "pult-rendezvous",
    "match": [{"path": ["/pult-link/*"]}],
    "handle": [
        {"handler": "rewrite", "strip_path_prefix": "/pult-link"},
        {"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:8787"}]},
    ],
    "terminal": True,
}


def install():
    try:
        with urlopen(ADMIN + "/id/pult-rendezvous", timeout=3):
            return
    except HTTPError as error:
        if error.code != 404:
            raise
    with urlopen(ADMIN + "/config/apps/http/servers", timeout=3) as response:
        servers = json.load(response)
    names = [name for name, server in servers.items() if any(item.endswith(":443") for item in server.get("listen", []))]
    if len(names) != 1:
        raise RuntimeError("Expected exactly one HTTPS server")
    path = "/config/apps/http/servers/" + names[0] + "/routes"
    with urlopen(ADMIN + path, timeout=3) as response:
        etag = response.headers["Etag"]
    request = Request(ADMIN + path + "/0", data=json.dumps(ROUTE).encode(), method="PUT",
                      headers={"Content-Type": "application/json", "If-Match": etag})
    with urlopen(request, timeout=5):
        pass


if __name__ == "__main__":
    for attempt in range(5):
        try:
            install()
            break
        except Exception:
            if attempt == 4:
                raise
            time.sleep(1)
