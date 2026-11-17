#!/usr/bin/env python3
"""Check that "remove torrent and its content" deletes the content in edge cases.

Case 1: the torrent is removed while its storage is being moved. libtorrent
finishes the move first, so the content must be deleted from the destination.

Case 2: the torrent is removed right after one of its files was renamed, before
the next periodic status update. The renamed file must still be deleted.

Case 3: qBittorrent is closed right after a torrent is removed, before libtorrent
confirms the removal. The content must be deleted before the process exits.
"""

import argparse
import hashlib
import json
import time
from pathlib import Path

from completed_storage import Client, bencode

# A long refresh interval keeps the cached torrent status old for a long time.
# This makes the rename case fail every time without the fix, not only by chance.
RENAME_CASE_REFRESH_INTERVAL_MS = 10000
PIECE_LENGTH = 4 * 1024 * 1024


def make_torrent(root, name, files):
    """Write the files under root/name and return the matching metainfo.

    files maps a file name to its size. All files contain zeros only, so each
    full piece has the same hash and large files are cheap to describe.
    """
    folder = root / name
    folder.mkdir(parents=True)
    for filename, size in files.items():
        with open(folder / filename, "wb") as file:
            file.truncate(size)
    total = sum(files.values())
    full_piece_hash = hashlib.sha1(bytes(PIECE_LENGTH), usedforsecurity=False).digest()
    pieces = full_piece_hash * (total // PIECE_LENGTH)
    if total % PIECE_LENGTH:
        pieces += hashlib.sha1(bytes(total % PIECE_LENGTH), usedforsecurity=False).digest()
    return bencode({b"info": {
        b"name": name.encode(), b"private": 1, b"piece length": PIECE_LENGTH, b"pieces": pieces,
        b"files": [{b"length": size, b"path": [filename.encode()]} for filename, size in files.items()]
    }})


def new_client(executable, root, refresh_interval_ms=None):
    client = Client(executable, root, "SQLite")
    if refresh_interval_ms is not None:
        config = client.profile / "qBittorrent" / "config" / "qBittorrent.ini"
        # The generated configuration ends with the [BitTorrent] section.
        with open(config, "a", encoding="utf-8") as file:
            file.write(f"Session\\RefreshInterval={refresh_interval_ms}\n")
    return client


def print_torrent_log(client, name):
    log = client.profile / "qBittorrent" / "data" / "logs" / "qbittorrent.log"
    if log.exists():
        for line in log.read_text(encoding="utf-8").splitlines():
            if name in line or "content" in line.lower():
                print("qBittorrent log:", line, flush=True)


def removed_before_move_finished(client, name):
    """Use the log order to tell whether the removal happened during the move."""
    log = (client.profile / "qBittorrent" / "data" / "logs" / "qbittorrent.log").read_text(encoding="utf-8")
    removed = log.find(f'Torrent removed. Torrent: "{name}"')
    # Once the torrent is removed, the move messages name it by its hash instead.
    moved = max(log.find(f'{message}. Torrent: "{label}"')
                for message in ("Moved torrent successfully", "Failed to move torrent")
                for label in (name, client.hash))
    assert removed >= 0 and moved >= 0, "The log does not show both the move and the removal"
    return removed < moved


def leftover_files(*folders):
    return sorted(str(path) for folder in folders if folder.exists() for path in folder.rglob("*") if path.is_file())


def remove_with_content(client):
    client.api("torrents/delete", {"hashes": client.hash, "deleteFiles": "true"})
    client.wait(lambda rows: not rows, "torrent removed")


def wait_until_removed(label, *folders, timeout=120):
    # The content folder of the current location must be gone too. Empty folders
    # that a finished move leaves at the old location do not matter here.
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not leftover_files(*folders) and not folders[-1].exists():
            return
        time.sleep(0.2)
    raise AssertionError(f"{label}: content was not removed: {leftover_files(*folders)}")


def removal_during_move(executable, root, move_root, require_race):
    client = new_client(executable, root)
    name = "remove-during-move"
    metainfo = make_torrent(client.final, name, {"large.bin": 1024 * 1024 * 1024, "small.bin": 1000})
    destination = move_root / "destination"
    try:
        client.launch()
        client.add(metainfo, False)
        # Remove the torrent right after the move starts. The API cannot show
        # reliably whether the move is still running, so check the log afterwards.
        client.api("torrents/setLocation", {"hashes": client.hash, "location": str(destination)})
        remove_with_content(client)
        wait_until_removed("removal during move", client.final / name, destination / name)
        client.close()
        during_move = removed_before_move_finished(client, name)
        print(json.dumps({"case": "removal-during-move", "removed_while_moving": during_move}), flush=True)
        if require_race and not during_move:
            raise AssertionError("The move finished before the torrent was removed, so the case was not tested")
    except Exception:
        client.close()
        print_torrent_log(client, name)
        raise
    finally:
        client.close()


def removal_after_rename(executable, root):
    client = new_client(executable, root, RENAME_CASE_REFRESH_INTERVAL_MS)
    name = "remove-after-rename"
    metainfo = make_torrent(client.final, name, {"first.bin": 50000, "second.bin": 70000})
    try:
        client.launch()
        client.add(metainfo, False)
        client.api("torrents/renameFile", {"hash": client.hash, "oldPath": f"{name}/first.bin",
                                           "newPath": f"{name}/renamed.bin"})
        files_query = "torrents/files?hash=" + client.hash
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            names = [entry["name"] for entry in json.loads(client.api(files_query))]
            if f"{name}/renamed.bin" in names:
                break
            time.sleep(0.02)
        else:
            raise AssertionError("The file was not renamed")
        assert (client.final / name / "renamed.bin").exists()
        remove_with_content(client)
        wait_until_removed("removal after rename", client.final / name, timeout=30)
        print(json.dumps({"case": "removal-after-rename"}), flush=True)
    except Exception:
        client.close()
        print_torrent_log(client, name)
        raise
    finally:
        client.close()


def removal_before_shutdown(executable, root, move_root, require_race):
    client = new_client(executable, root)
    name = "remove-before-shutdown"
    metainfo = make_torrent(client.final, name, {"large.bin": 1024 * 1024 * 1024, "small.bin": 1000})
    destination = move_root / "shutdown-destination"
    try:
        client.launch()
        client.add(metainfo, False)
        # Removing during a move to another drive delays libtorrent's confirmation
        # by several seconds, so the application is closed before it arrives.
        client.api("torrents/setLocation", {"hashes": client.hash, "location": str(destination)})
        remove_with_content(client)
        client.close()
        # Check right after the process exits. Nothing deletes the content later.
        leftover = leftover_files(client.final / name, destination / name)
        assert not leftover, f"removal before shutdown: content was not removed: {leftover}"
        during_move = removed_before_move_finished(client, name)
        print(json.dumps({"case": "removal-before-shutdown", "removed_while_moving": during_move}), flush=True)
        if require_race and not during_move:
            raise AssertionError("The move finished before the torrent was removed, so the case was not tested")
    except Exception:
        client.close()
        print_torrent_log(client, name)
        raise
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--move-root", type=Path,
                        help="Destination for the move case. Use another drive to make the move slow.")
    parser.add_argument("--require-race", action="store_true",
                        help="Fail if the torrent could not be removed while it was moving.")
    args = parser.parse_args()
    executable = args.exe.resolve(strict=True)
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=False)
    move_root = (args.move_root or (root / "move")).resolve()
    move_root.mkdir(parents=True, exist_ok=False)
    removal_during_move(executable, root / "move-case", move_root, args.require_race)
    removal_after_rename(executable, root / "rename-case")
    removal_before_shutdown(executable, root / "shutdown-case", move_root, args.require_race)
    print("PASS: remove content regression", flush=True)


if __name__ == "__main__":
    main()
