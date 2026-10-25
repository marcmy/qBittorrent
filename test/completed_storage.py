#!/usr/bin/env python3
"""Exercise completed-storage policy with private, generated loopback torrents."""

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import sqlite3
# The regression launches only its explicitly supplied qBittorrent test build.
import subprocess  # nosec B404
import time
import urllib.parse
import urllib.request
from pathlib import Path


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, list):
        return b"l" + b"".join(map(bencode, value)) + b"e"
    if isinstance(value, dict):
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in sorted(value.items())) + b"e"
    raise TypeError(type(value))


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Client:
    def __init__(self, executable, root, backend):
        self.executable = executable
        self.root = root
        self.final = root / "final"
        self.temporary = root / "temporary"
        self.profile = root / "profile"
        self.port = free_port()
        self.peer_port = free_port()
        while self.peer_port == self.port:
            self.peer_port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.process = None
        self.hash = None
        self.backend = backend
        config = self.profile / "qBittorrent" / "config"
        config.mkdir(parents=True)
        self.final.mkdir()
        self.temporary.mkdir()
        salt = os.urandom(16)
        secret = base64.b64encode(salt).decode() + ":" + base64.b64encode(
            hashlib.pbkdf2_hmac("sha512", b"generated-fixture-only", salt, 100000, 64)).decode()
        (config / "qBittorrent.ini").write_text(
            "[WebUI]\nEnabled=true\nAddress=127.0.0.1\nLocalHostAuth=false\n"
            f"Username=fixture\nPort={self.port}\nPassword_PBKDF2=\"@ByteArray({secret})\"\n"
            "[LegalNotice]\nAccepted=true\n[Preferences]\nAdvanced\\updateCheck=false\n"
            "[Network]\nPortForwardingEnabled=false\n[BitTorrent]\n"
            f"Session\\ResumeDataStorageType={backend}\n"
            "Session\\DHTEnabled=false\nSession\\LSDEnabled=false\nSession\\PeXEnabled=false\n"
            "Session\\QueueingSystemEnabled=false\nSession\\UseUnwantedFolder=false\n"
            "Session\\AddExtensionToIncompleteFiles=false\nSession\\TempPathEnabled=true\n"
            f"Session\\TempPath={self.temporary.as_posix()}\n"
            f"Session\\DefaultSavePath={self.final.as_posix()}\n", encoding="utf-8")

    def api(self, action, fields=None, content_type=None):
        if isinstance(fields, dict):
            fields = urllib.parse.urlencode(fields).encode()
            content_type = "application/x-www-form-urlencoded"
        headers = {"Origin": self.url, "Referer": self.url + "/"}
        if content_type:
            headers["Content-Type"] = content_type
        request = urllib.request.Request(self.url + "/api/v2/" + action, data=fields, headers=headers)
        with self.opener.open(request, timeout=5) as response:
            return response.read()

    def rows(self):
        return json.loads(self.api("torrents/info"))

    def wait(self, predicate, label, timeout=45):
        deadline = time.monotonic() + timeout
        rows = []
        while time.monotonic() < deadline:
            try:
                rows = self.rows()
                if predicate(rows):
                    return rows
            except OSError:
                if self.process.poll() is not None:
                    raise RuntimeError(f"Fixture process exited: {self.process.returncode}")
            time.sleep(0.1)
        raise RuntimeError(f"Timeout: {label}: {rows}")

    def launch(self):
        options = {}
        if os.name == "nt":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
            options["startupinfo"] = startup
        # Fixed argument vector and no shell; the executable is supplied by CI.
        self.process = subprocess.Popen([  # nosec B603
            str(self.executable), "--profile=" + str(self.profile),
            "--webui-port=" + str(self.port), "--torrenting-port=" + str(self.peer_port),
            "--no-splash", "--confirm-legal-notice"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **options)
        self.wait(lambda rows: True, "isolated Web API")

    def close(self):
        if self.process is None:
            return
        try:
            if self.process.poll() is None:
                self.api("app/shutdown", {})
                self.process.wait(timeout=45)
        finally:
            if self.process.poll() is None:
                self.process.terminate()
                self.process.wait(timeout=10)
            self.process = None

    def add(self, torrent, use_temporary):
        boundary = "generated-storage-regression"
        fields = {"savepath": str(self.final), "downloadPath": str(self.temporary),
                  "useDownloadPath": str(use_temporary).lower(), "autoTMM": "false",
                  "stopped": "true", "contentLayout": "Original"}
        payload = b""
        for name, value in fields.items():
            payload += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").encode()
        payload += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"torrents\"; "
                    "filename=\"fixture.torrent\"\r\nContent-Type: application/x-bittorrent\r\n\r\n").encode()
        payload += torrent + f"\r\n--{boundary}--\r\n".encode()
        self.api("torrents/add", payload, "multipart/form-data; boundary=" + boundary)
        rows = self.wait(lambda rows: len(rows) == 1 and "checking" not in rows[0]["state"].lower(), "added fixture")
        self.hash = rows[0]["hash"]

    def command(self, action):
        self.api("torrents/" + action, {"hashes": self.hash})

    def priority(self, index, priority):
        self.api("torrents/filePrio", {"hash": self.hash, "id": index, "priority": priority})

    def connect(self, seed):
        self.api("torrents/addPeers", {"hashes": self.hash, "peers": f"127.0.0.1:{seed.peer_port}"})

    def recheck(self):
        self.command("stop")
        self.command("recheck")
        # Rechecking a stopped torrent starts it with FilesChecked as its stop
        # condition. The API's stopped filter reads isStopped() directly, while
        # the displayed state/progress may still describe the preceding check.
        stopped_query = "torrents/info?filter=stopped&hashes=" + self.hash
        self.wait(lambda rows: bool(json.loads(self.api(stopped_query))), "recheck stop condition")
        return self.wait(lambda rows: len(rows) == 1 and not any(
            word in rows[0]["state"].lower() for word in ("checking", "moving")), "recheck storage settled")[0]


def run_case(executable, root, backend, baseline):
    seed = Client(executable, root / "seed", "Legacy")
    client = Client(executable, root / "download", backend)
    name = "generated-storage-fixture"
    files = {"keep.bin": b"a" * 24576, "later.bin": b"b" * 40960, "anchor.bin": b"c" * 32768}
    content = b"".join(files.values())
    piece_hashes = b"".join(hashlib.sha1(content[i:i+16384], usedforsecurity=False).digest()
                            for i in range(0, len(content), 16384))
    metainfo = bencode({b"info": {
        b"name": name.encode(), b"private": 1, b"piece length": 16384, b"pieces": piece_hashes,
        b"files": [{b"length": len(data), b"path": [filename.encode()]} for filename, data in files.items()]
    }})
    for filename, data in files.items():
        destination = seed.final / name / filename
        destination.parent.mkdir(exist_ok=True)
        destination.write_bytes(data)
    stages = []

    def record(label):
        row = client.rows()[0]
        stage = {"stage": label, "state": row["state"], "progress": row["progress"],
                 "final_files": sorted(path.name for path in (client.final / name).glob("*.bin")),
                 "temporary_files": sorted(path.name for path in (client.temporary / name).glob("*.bin"))}
        stages.append(stage)
        print(json.dumps({"backend": backend, **stage}), flush=True)
        return row

    def retained():
        for filename in ("keep.bin", "anchor.bin"):
            assert (client.final / name / filename).read_bytes() == files[filename], filename
            assert not (client.temporary / name / filename).exists(), filename

    def complete():
        seed.command("start")
        client.command("start")
        client.connect(seed)
        client.wait(lambda rows: len(rows) == 1 and rows[0]["progress"] == 1
                    and (client.final / name / "keep.bin").exists(), "completed download")
        client.command("stop")
        seed.command("stop")
        client.wait(lambda rows: rows[0]["state"].startswith("stopped"), "stopped fixture")

    try:
        seed.launch()
        seed.add(metainfo, False)
        client.launch()
        client.add(metainfo, True)
        client.priority(1, 0)
        # Brand-new downloads and incomplete rechecks must still use temp.
        client.recheck()
        client.close()
        if backend == "SQLite":
            db = sqlite3.connect(client.profile / "qBittorrent" / "data" / "torrents.db")
            saved = db.execute("select libtorrent_resume_data from torrents").fetchone()[0]
            db.close()
            assert str(client.temporary).replace("\\", "/").encode() in saved.replace(b"\\", b"/"), saved
        client.launch()
        client.wait(lambda rows: len(rows) == 1, "resumed new download")
        complete()
        retained()
        record("initial-completion")
        client.recheck()
        retained()
        record("complete-recheck")
        client.close()
        # Exercise upgrade from the pre-latch resume format as well as new data.
        if not baseline and backend == "SQLite":
            db = sqlite3.connect(client.profile / "qBittorrent" / "data" / "torrents.db")
            db.execute("alter table torrents drop column has_finished_storage")
            db.execute("update meta set value=10 where name='version'")
            db.commit()
            db.close()
        elif not baseline:
            resume = next((client.profile / "qBittorrent" / "data" / "BT_backup").glob("*.fastresume"))
            marker = bencode(b"qBt-finishedStorage") + b"i1e"
            data = resume.read_bytes()
            assert data.count(marker) == 1
            resume.write_bytes(data.replace(marker, b""))
        parts = list(client.final.rglob("*.parts"))
        assert parts, "Shared pieces must create a real part file"
        for part in parts:
            assert client.root.resolve() in part.resolve().parents
            part.unlink()
        client.launch()
        client.wait(lambda rows: len(rows) == 1, "restart without part file")
        row = client.recheck()
        record("part-file-removed-recheck")
        if baseline:
            assert (client.temporary / name / "keep.bin").exists(), "Baseline did not reproduce backward move"
            return stages
        assert row["progress"] < 1, row
        retained()
        complete()
        retained()
        client.priority(1, 1)
        client.wait(lambda rows: rows[0]["progress"] < 1, "newly selected file is incomplete")
        client.recheck()
        retained()
        record("select-previously-ignored-file")
        client.api("torrents/setAutoManagement", {"hashes": client.hash, "enable": "true"})
        client.close()
        if backend == "SQLite":
            db = sqlite3.connect(client.profile / "qBittorrent" / "data" / "torrents.db")
            row = db.execute("select has_finished_storage, has_seed_status from torrents").fetchone()
            db.close()
            assert row == (1, 0), row
        else:
            resume = next((client.profile / "qBittorrent" / "data" / "BT_backup").glob("*.fastresume"))
            assert bencode(b"qBt-finishedStorage") + b"i1e" in resume.read_bytes()
        # With completion status false, only the separately saved storage stage
        # can distinguish an old final folder from an old incomplete folder when
        # automatic management's final path changes while the app is stopped.
        client.final = client.root / "second-final"
        client.final.mkdir()
        config = client.profile / "qBittorrent" / "config" / "qBittorrent.ini"
        settings, count = re.subn(
            r"(?m)^Session\\DefaultSavePath=.*$",
            lambda match: "Session\\DefaultSavePath=" + client.final.as_posix(), config.read_text())
        assert count == 1, settings
        config.write_text(settings, encoding="utf-8")
        client.launch()
        client.wait(lambda rows: len(rows) == 1 and (client.final / name / "anchor.bin").exists(),
                    "restart into new automatically managed final folder")
        client.recheck()
        retained()
        record("incomplete-restart-and-recheck")
        client.api("torrents/setAutoManagement", {"hashes": client.hash, "enable": "false"})
        alternative_temp = client.root / "another-temporary"
        client.api("torrents/setDownloadPath", {"id": client.hash, "path": str(alternative_temp)})
        time.sleep(1)
        retained()
        assert not list(alternative_temp.rglob("*.bin"))
        record("change-incomplete-folder")
        destination = client.root / "explicit-move"
        client.api("torrents/setLocation", {"hashes": client.hash, "location": str(destination)})
        client.wait(lambda rows: (destination / name / "anchor.bin").exists(), "explicit move")
        client.final = destination
        retained()
        record("explicit-user-relocation-while-incomplete")
        complete()
        for filename, data in files.items():
            assert (client.final / name / filename).read_bytes() == data, filename
        record("additional-file-downloaded-on-final-drive")
        return stages
    finally:
        try:
            client.close()
        finally:
            seed.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    executable = args.exe.resolve(strict=True)
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=False)
    results = {}
    for backend in ("SQLite",) if args.baseline else ("SQLite", "Legacy"):
        results[backend] = run_case(executable, root / backend, backend, args.baseline)
    (root / "result.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    print("PASS: completed storage regression", flush=True)


if __name__ == "__main__":
    main()
