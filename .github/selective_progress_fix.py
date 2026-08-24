from pathlib import Path

path = Path("src/base/bittorrent/torrentimpl.cpp")
text = path.read_text(encoding="utf-8")

old_block = '''    const QBitArray oldPieces = std::exchange(m_pieces, LT::toQBitArray(m_nativeStatus.pieces));
    const QBitArray newPieces = m_pieces ^ oldPieces;

    const int64_t pieceSize = m_torrentInfo.pieceLength();
    for (qsizetype index = 0; index < newPieces.size(); ++index)
    {
        if (!newPieces.at(index))
            continue;

        int64_t size = m_torrentInfo.pieceLength(index);
        int64_t pieceOffset = index * pieceSize;

        for (const int fileIndex : asConst(m_torrentInfo.fileIndicesForPiece(index)))
        {
            const int64_t fileOffsetInPiece = pieceOffset - m_torrentInfo.fileOffset(fileIndex);
            const int64_t add = std::min<int64_t>((m_torrentInfo.fileSize(fileIndex) - fileOffsetInPiece), size);

            m_filesProgress[fileIndex] += add;

            size -= add;
            if (size <= 0)
                break;

            pieceOffset += add;
        }
    }
'''

new_block = '''    const QBitArray oldPieces = std::exchange(m_pieces, LT::toQBitArray(m_nativeStatus.pieces));
    const QBitArray changedPieces = m_pieces ^ oldPieces;

    const int64_t pieceSize = m_torrentInfo.pieceLength();
    for (qsizetype index = 0; index < changedPieces.size(); ++index)
    {
        if (!changedPieces.at(index))
            continue;

        const bool havePiece = m_pieces.at(index);
        int64_t size = m_torrentInfo.pieceLength(index);
        int64_t pieceOffset = index * pieceSize;

        for (const int fileIndex : asConst(m_torrentInfo.fileIndicesForPiece(index)))
        {
            const int64_t fileSize = m_torrentInfo.fileSize(fileIndex);
            const int64_t fileOffsetInPiece = pieceOffset - m_torrentInfo.fileOffset(fileIndex);
            const int64_t change = std::min<int64_t>((fileSize - fileOffsetInPiece), size);

            if (havePiece)
            {
                m_filesProgress[fileIndex] = std::min<int64_t>(fileSize, m_filesProgress[fileIndex] + change);
            }
            else
            {
                m_filesProgress[fileIndex] = std::max<int64_t>(0, m_filesProgress[fileIndex] - change);
                m_completedFiles.clearBit(fileIndex);
            }

            size -= change;
            if (size <= 0)
                break;

            pieceOffset += change;
        }
    }

    if (!isFinished())
        m_hasFinishedStatus = false;
'''

count = text.count(old_block)
if count != 1:
    raise SystemExit(f"expected exactly one updateProgress block, found {count}")

path.write_text(text.replace(old_block, new_block), encoding="utf-8")
