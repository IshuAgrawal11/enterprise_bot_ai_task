import os
import socket
from pathlib import Path

from fastapi import FastAPI

app = FastAPI()

CONFIG_DIR = Path("/etc/config")


def get_config_val(key: str, default: str) -> str:
    env_value = os.getenv(key)
    if env_value:
        return env_value

    file_path = CONFIG_DIR / key

    if file_path.is_file():
        try:
            val = file_path.read_text(encoding="utf-8").strip()
            if val:
                return val
        except OSError:
            pass

    return default

@app.get("/")
def root():
    return {
        "app": get_config_val("APP_NAME", "demo-app"),
        "version": get_config_val("VERSION", "1.0.0"),
        "pod": socket.gethostname(),
    }


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
