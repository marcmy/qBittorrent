from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected exactly one match, found {count}")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")


replace_once(
    "src/base/bittorrent/torrent.h",
    "        virtual void forceDHTAnnounce() = 0;\n"
    "        virtual void forceRecheck() = 0;\n"
    "        virtual void setUploadLimit(int limit) = 0;",
    "        virtual void forceDHTAnnounce() = 0;\n"
    "        virtual void forceRecheck() = 0;\n"
    "        virtual void recheckFiles(const QList<int> &indexes) = 0;\n"
    "        virtual void setUploadLimit(int limit) = 0;",
)

replace_once(
    "src/base/bittorrent/torrentimpl.h",
    "        void forceDHTAnnounce() override;\n"
    "        void forceRecheck() override;\n"
    "        void renameFile(int index, const Path &path) override;",
    "        void forceDHTAnnounce() override;\n"
    "        void forceRecheck() override;\n"
    "        void recheckFiles(const QList<int> &indexes) override;\n"
    "        void renameFile(int index, const Path &path) override;",
)

replace_once(
    "src/base/bittorrent/torrentimpl.cpp",
    "#include <algorithm>\n#include <memory>\n",
    "#include <algorithm>\n#include <memory>\n#include <vector>\n",
)

implementation = (
    "void TorrentImpl::recheckFiles(const QList<int> &indexes)\n"
    "{\n"
    "    if (!hasMetadata() || indexes.isEmpty())\n"
    "        return;\n"
    "\n"
    "    std::vector<lt::file_index_t> nativeIndexes;\n"
    "    nativeIndexes.reserve(static_cast<std::size_t>(indexes.size()));\n"
    "\n"
    "    for (const int index : indexes)\n"
    "    {\n"
    "        if ((index < 0) || (index >= filesCount()))\n"
    "            continue;\n"
    "\n"
    "        nativeIndexes.push_back(m_torrentInfo.nativeIndexes().at(index));\n"
    "    }\n"
    "\n"
    "    if (!nativeIndexes.empty())\n"
    "        m_nativeHandle.recheck_files(std::move(nativeIndexes));\n"
    "}\n"
)

replace_once(
    "src/base/bittorrent/torrentimpl.cpp",
    "\nvoid TorrentImpl::setSequentialDownload(const bool enable)\n",
    "\n" + implementation + "\nvoid TorrentImpl::setSequentialDownload(const bool enable)\n",
)

replace_once(
    "src/gui/torrentcontentwidget.cpp",
    '#include "base/bittorrent/torrentcontenthandler.h"\n',
    '#include "base/bittorrent/torrent.h"\n'
    '#include "base/bittorrent/torrentcontenthandler.h"\n',
)

menu = (
    "    if (auto *torrent = qobject_cast<BitTorrent::Torrent *>(contentHandler()))\n"
    "    {\n"
    "        menu->addAction(tr(\"Recheck selected files\"), this, [this, torrent]\n"
    "        {\n"
    "            QSet<int> fileIndexes;\n"
    "            const QModelIndexList rows = selectionModel()->selectedRows(0);\n"
    "            for (const QModelIndex &row : rows)\n"
    "                fileIndexes.unite(m_filterModel->getFileIndexes(row));\n"
    "\n"
    "            if (!fileIndexes.isEmpty())\n"
    "                torrent->recheckFiles(fileIndexes.values());\n"
    "        });\n"
    "        menu->addSeparator();\n"
    "    }\n"
)

replace_once(
    "src/gui/torrentcontentwidget.cpp",
    '    menu->addAction(UIThemeManager::instance()->getIcon(u"edit-rename"_s), tr("Batch rename...")\n'
    '            , this, &TorrentContentWidget::batchRenameFiles);\n'
    "    menu->addSeparator();\n\n"
    '    QMenu *subMenu = menu->addMenu(tr("Priority"));',
    '    menu->addAction(UIThemeManager::instance()->getIcon(u"edit-rename"_s), tr("Batch rename...")\n'
    '            , this, &TorrentContentWidget::batchRenameFiles);\n'
    "    menu->addSeparator();\n"
    + menu
    + '\n    QMenu *subMenu = menu->addMenu(tr("Priority"));',
)
