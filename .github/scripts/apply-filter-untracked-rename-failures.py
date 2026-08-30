from pathlib import Path

path = Path("src/base/bittorrent/torrentimpl.cpp")
text = path.read_text(encoding="utf-8")
old = """void TorrentImpl::handleFileRenameFailed(const lt::file_index_t nativeFileIndex)\n{\n    const int fileIndex = fileIndexFromNative(nativeFileIndex);\n    Q_ASSERT(fileIndex >= 0);\n\n    const FileRenameInfo currentFileRenameInfo = m_renamingFiles.dequeue();\n"""
new = """void TorrentImpl::handleFileRenameFailed(const lt::file_index_t nativeFileIndex)\n{\n    const int fileIndex = fileIndexFromNative(nativeFileIndex);\n    Q_ASSERT(fileIndex >= 0);\n\n    if (m_renamingFiles.isEmpty() || (m_renamingFiles.head().index != fileIndex))\n        return;\n\n    const FileRenameInfo currentFileRenameInfo = m_renamingFiles.dequeue();\n"""
count = text.count(old)
if count != 1:
    raise RuntimeError(f"expected exactly one handleFileRenameFailed match, found {count}")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
