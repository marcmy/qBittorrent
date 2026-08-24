from pathlib import Path

path = Path(".github/workflows/ci_windows.yaml")
text = path.read_text(encoding="utf-8")

old = "custom/qbittorrent-2.1"
new = "fix/selective-recheck-crash"
count = text.count(old)
if count != 4:
    raise SystemExit(f"expected 4 libtorrent defaults, found {count}")

path.write_text(text.replace(old, new), encoding="utf-8")
