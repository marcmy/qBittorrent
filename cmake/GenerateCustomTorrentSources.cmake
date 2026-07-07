# Generate fork-specific BitTorrent sources without rewriting large upstream files.
# Exact anchors intentionally fail configuration when upstream changes the patched areas.

foreach(required_var IN ITEMS
        QBT_TORRENTIMPL_INPUT QBT_TORRENTIMPL_OUTPUT
        QBT_DBRESUMEDATA_INPUT QBT_DBRESUMEDATA_OUTPUT)
    if (NOT DEFINED ${required_var})
        message(FATAL_ERROR "GenerateCustomTorrentSources: ${required_var} is not defined")
    endif()
endforeach()

function(qbt_replace_exact variable old_text new_text description)
    set(value "${${variable}}")
    string(LENGTH "${value}" before_length)
    string(REPLACE "${old_text}" "" value_without_match "${value}")
    string(LENGTH "${value_without_match}" after_length)
    string(LENGTH "${old_text}" match_length)

    if (match_length EQUAL 0)
        message(FATAL_ERROR "GenerateCustomTorrentSources: empty anchor for ${description}")
    endif()

    math(EXPR match_count "(${before_length} - ${after_length}) / ${match_length}")
    if (NOT match_count EQUAL 1)
        message(FATAL_ERROR
            "GenerateCustomTorrentSources: expected exactly one ${description} anchor, found ${match_count}")
    endif()

    string(REPLACE "${old_text}" "${new_text}" value "${value}")
    set(${variable} "${value}" PARENT_SCOPE)
endfunction()

function(qbt_replace_between variable start_marker end_marker replacement description)
    set(value "${${variable}}")
    string(FIND "${value}" "${start_marker}" start_position)
    string(FIND "${value}" "${end_marker}" end_position)

    if ((start_position EQUAL -1) OR (end_position EQUAL -1) OR (end_position LESS_EQUAL start_position))
        message(FATAL_ERROR "GenerateCustomTorrentSources: could not locate ${description}")
    endif()

    string(SUBSTRING "${value}" 0 ${start_position} prefix)
    string(SUBSTRING "${value}" ${end_position} -1 suffix)
    set(${variable} "${prefix}${replacement}${suffix}" PARENT_SCOPE)
endfunction()

file(READ "${QBT_TORRENTIMPL_INPUT}" torrent_impl)

qbt_replace_exact(torrent_impl
[=[#include <QByteArray>
#include <QCache>]=]
[=[#include <QByteArray>
#include <QCache>
#include <QCryptographicHash>]=]
"QCryptographicHash include")

qbt_replace_exact(torrent_impl
[=[    PathList makeCollisionSafeFilePaths(const PathList &filePaths, const QString &suffix)
]=]
[=[    QSet<QString> claimedPaths(const Torrent *torrent)
    {
        QSet<QString> result;
        const PathList logicalPaths = torrent->filePaths();
        const PathList actualPaths = torrent->actualFilePaths();
        const QList<DownloadPriority> priorities = torrent->filePriorities();

        const auto addPaths = [&result, &priorities](const Path &basePath, const PathList &paths)
        {
            if (basePath.isEmpty())
                return;

            for (qsizetype i = 0; i < paths.size(); ++i)
            {
                if (priorities.value(i, DownloadPriority::Normal) == DownloadPriority::Ignored)
                    continue;
                result.insert(pathCollisionKey(basePath / paths.at(i)));
            }
        };

        addPaths(torrent->actualStorageLocation(), actualPaths);
        addPaths(torrent->actualStorageLocation(), logicalPaths);
        addPaths(torrent->savePath(), logicalPaths);
        addPaths(torrent->downloadPath(), logicalPaths);
        return result;
    }

    QString sharedPathSignature(const Torrent *torrent)
    {
        QSet<QString> mappedPaths;
        const PathList logicalPaths = torrent->filePaths();
        const QList<DownloadPriority> priorities = torrent->filePriorities();

        const auto addPaths = [&mappedPaths, &priorities](const Path &basePath, const PathList &paths)
        {
            if (basePath.isEmpty())
                return;

            for (qsizetype i = 0; i < paths.size(); ++i)
            {
                if (priorities.value(i, DownloadPriority::Normal) == DownloadPriority::Ignored)
                    continue;
                mappedPaths.insert(pathCollisionKey(basePath / paths.at(i)));
            }
        };

        addPaths(torrent->actualStorageLocation(), logicalPaths);
        addPaths(torrent->savePath(), logicalPaths);
        addPaths(torrent->downloadPath(), logicalPaths);

        QStringList paths = mappedPaths.values();
        std::sort(paths.begin(), paths.end());

        QByteArray signatureInput;
        for (const QString &path : paths)
        {
            const QByteArray encodedPath = path.toUtf8();
            signatureInput += QByteArray::number(encodedPath.size());
            signatureInput += ':';
            signatureInput += encodedPath;
        }

        return QString::fromLatin1(QCryptographicHash::hash(signatureInput, QCryptographicHash::Sha256).toHex());
    }

    struct PathCollisionInfo
    {
        QSet<QString> occupiedPaths;
        QStringList conflictingTorrents;
    };

    PathCollisionInfo findPathCollisions(const Torrent *torrent)
    {
        PathCollisionInfo result;
        const QSet<QString> ownClaimedPaths = claimedPaths(torrent);

        for (const Torrent *otherTorrent : torrent->session()->torrents())
        {
            if ((otherTorrent == torrent) || otherTorrent->isStopped() || !otherTorrent->hasMetadata())
                continue;

            const QSet<QString> otherClaimedPaths = claimedPaths(otherTorrent);
            bool conflicts = false;
            for (const QString &path : ownClaimedPaths)
            {
                if (otherClaimedPaths.contains(path))
                {
                    conflicts = true;
                    break;
                }
            }

            if (conflicts)
                result.conflictingTorrents.append(otherTorrent->name());
            result.occupiedPaths.unite(otherClaimedPaths);
        }

        std::sort(result.conflictingTorrents.begin(), result.conflictingTorrents.end());
        return result;
    }

    PathList makeCollisionSafeFilePaths(const PathList &filePaths, const QString &suffix)
]=]
"shared-path helper insertion")

qbt_replace_exact(torrent_impl
[=[    , m_contentLayout {params.contentLayout}
    , m_hasFinishedStatus {params.hasFinishedStatus}]=]
[=[    , m_contentLayout {params.contentLayout}
    , m_sharedContentPathSignature {params.sharedContentPathSignature}
    , m_hasFinishedStatus {params.hasFinishedStatus}]=]
"shared-path constructor initialization")

qbt_replace_exact(torrent_impl
[=[    if (resolvedPath == savePath())
        return;

    if (isFinished() || m_hasFinishedStatus || downloadPath().isEmpty())]=]
[=[    if (resolvedPath == savePath())
        return;

    if (!m_sharedContentPathSignature.isEmpty())
    {
        m_sharedContentPathSignature.clear();
        deferredRequestResumeData();
    }

    if (isFinished() || m_hasFinishedStatus || downloadPath().isEmpty())]=]
"save-path approval invalidation")

qbt_replace_exact(torrent_impl
[=[    if (resolvedPath == m_downloadPath)
        return;

    const bool isIncomplete]=]
[=[    if (resolvedPath == m_downloadPath)
        return;

    if (!m_sharedContentPathSignature.isEmpty())
    {
        m_sharedContentPathSignature.clear();
        deferredRequestResumeData();
    }

    const bool isIncomplete]=]
"download-path approval invalidation")

qbt_replace_exact(torrent_impl
[=[    if (m_useAutoTMM == enabled)
        return;

    m_useAutoTMM = enabled;]=]
[=[    if (m_useAutoTMM == enabled)
        return;

    m_sharedContentPathSignature.clear();
    m_useAutoTMM = enabled;]=]
"automatic-management approval invalidation")

qbt_replace_exact(torrent_impl
[=[void TorrentImpl::manageActualFilePaths()
{
    for (int i = 0; i < filesCount(); ++i)]=]
[=[void TorrentImpl::manageActualFilePaths()
{
    if (!m_sharedContentPathSignature.isEmpty())
    {
        if (m_sharedContentPathSignature == sharedPathSignature(this))
            return;

        m_sharedContentPathSignature.clear();
        deferredRequestResumeData();
    }

    for (int i = 0; i < filesCount(); ++i)]=]
"shared-path file-rename guard")

qbt_replace_exact(torrent_impl
[=[void TorrentImpl::adjustStorageLocation()
{
    const Path downloadPath = this->downloadPath();]=]
[=[void TorrentImpl::adjustStorageLocation()
{
    if (!m_sharedContentPathSignature.isEmpty())
    {
        if (m_sharedContentPathSignature == sharedPathSignature(this))
            return;

        m_sharedContentPathSignature.clear();
        deferredRequestResumeData();
    }

    const Path downloadPath = this->downloadPath();]=]
"shared-path storage-move guard")

set(new_collision_implementation
[=[bool TorrentImpl::preventPathCollision()
{
    if (!hasMetadata() || isStopped() || isChecking() || isFinished() || (progress() >= 1.0) || (wantedSize() <= 0))
        return false;

    const QString currentSignature = sharedPathSignature(this);
    if (!m_sharedContentPathSignature.isEmpty())
    {
        if (m_sharedContentPathSignature == currentSignature)
            return false;

        m_sharedContentPathSignature.clear();
        deferredRequestResumeData();
    }

    const PathCollisionInfo collisionInfo = findPathCollisions(this);
    if (collisionInfo.conflictingTorrents.isEmpty())
        return false;

#ifdef DISABLE_GUI
    resolvePathCollision(Torrent::PathCollisionResolution::CreateProtectedCopy);
#else
    stop();
    LogMsg(tr("Stopped torrent pending a shared-content decision. Torrent: \"%1\". Conflicting torrents: %2")
            .arg(name(), collisionInfo.conflictingTorrents.join(u", "_s)), Log::WARNING);
    emit pathCollisionDetected(collisionInfo.conflictingTorrents);
#endif
    return true;
}

void TorrentImpl::resolvePathCollision(const Torrent::PathCollisionResolution resolution)
{
    if (!hasMetadata())
        return;

    if (resolution == Torrent::PathCollisionResolution::UseExistingData)
    {
        m_sharedContentPathSignature = sharedPathSignature(this);
        deferredRequestResumeData();
        LogMsg(tr("Allowed torrent to use an existing shared content path for cross-seeding. Torrent: \"%1\". Path: \"%2\"")
                .arg(name(), contentPath().toString()), Log::WARNING);
        start(m_operatingMode);
        return;
    }

    const PathCollisionInfo collisionInfo = findPathCollisions(this);
    if (collisionInfo.conflictingTorrents.isEmpty())
    {
        start(m_operatingMode);
        return;
    }

    QList<Path> storageLocations;
    const auto addStorageLocation = [&storageLocations](const Path &path)
    {
        if (!path.isEmpty() && !storageLocations.contains(path))
            storageLocations.append(path);
    };
    addStorageLocation(actualStorageLocation());
    addStorageLocation(savePath());
    addStorageLocation(downloadPath());

    PathList safeFilePaths;
    const QString hashFragment = infoHash().toString().first(8);
    for (int attempt = 1; attempt <= 999; ++attempt)
    {
        const QString suffix = (attempt == 1)
                ? QStringLiteral(" [qB-%1]").arg(hashFragment)
                : QStringLiteral(" [qB-%1-%2]").arg(hashFragment).arg(attempt);
        const PathList candidatePaths = makeCollisionSafeFilePaths(filePaths(), suffix);
        const Path candidateRoot = Path::findRootFolder(candidatePaths);

        bool available = true;
        for (const Path &storageLocation : asConst(storageLocations))
        {
            if (!candidateRoot.isEmpty() && (storageLocation / candidateRoot).exists())
            {
                available = false;
                break;
            }

            for (const Path &candidatePath : candidatePaths)
            {
                const Path absolutePath = storageLocation / candidatePath;
                if (absolutePath.exists() || collisionInfo.occupiedPaths.contains(pathCollisionKey(absolutePath)))
                {
                    available = false;
                    break;
                }
            }

            if (!available)
                break;
        }

        if (available)
        {
            safeFilePaths = candidatePaths;
            break;
        }
    }

    if (safeFilePaths.isEmpty())
    {
        stop();
        LogMsg(tr("Stopped torrent because no collision-safe content path could be allocated. Torrent: \"%1\". Conflicting torrents: %2")
                .arg(name(), collisionInfo.conflictingTorrents.join(u", "_s)), Log::CRITICAL);
        return;
    }

    m_sharedContentPathSignature.clear();
    const Path oldContentPath = contentPath();
    reloadWithFilePaths(safeFilePaths);
    deferredRequestResumeData();
    LogMsg(tr("Protected torrent data by assigning a collision-safe content path. Torrent: \"%1\". Old path: \"%2\". New path: \"%3\". Conflicting torrents: %4")
            .arg(name(), oldContentPath.toString(), contentPath().toString(), collisionInfo.conflictingTorrents.join(u", "_s)), Log::WARNING);
    start(m_operatingMode);
}

]=])

qbt_replace_between(torrent_impl
    "bool TorrentImpl::preventPathCollision()\n"
    "void TorrentImpl::reloadWithFilePaths"
    "${new_collision_implementation}"
    "path-collision implementation")

qbt_replace_exact(torrent_impl
[=[        .useAutoTMM = m_useAutoTMM,
        .firstLastPiecePriority = m_hasFirstLastPiecePriority,
        .hasFinishedStatus = m_hasFinishedStatus,]=]
[=[        .useAutoTMM = m_useAutoTMM,
        .firstLastPiecePriority = m_hasFirstLastPiecePriority,
        .sharedContentPathSignature = m_sharedContentPathSignature,
        .hasFinishedStatus = m_hasFinishedStatus,]=]
"shared-path resume-data persistence")

get_filename_component(torrent_impl_output_dir "${QBT_TORRENTIMPL_OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${torrent_impl_output_dir}")
file(WRITE "${QBT_TORRENTIMPL_OUTPUT}" "${torrent_impl}")

file(READ "${QBT_DBRESUMEDATA_INPUT}" db_resume_data)

qbt_replace_exact(db_resume_data
[=[    const lt::bdecode_node resumeDataRoot = lt::bdecode(bencodedResumeData, ec, nullptr, bdecodeDepthLimit, bdecodeTokenLimit);
    if (ec)
        return nonstd::make_unexpected(tr("Cannot parse resume data: %1").arg(QString::fromStdString(ec.message())));

    lt::add_torrent_params &p = resumeData.ltAddTorrentParams;]=]
[=[    const lt::bdecode_node resumeDataRoot = lt::bdecode(bencodedResumeData, ec, nullptr, bdecodeDepthLimit, bdecodeTokenLimit);
    if (ec)
        return nonstd::make_unexpected(tr("Cannot parse resume data: %1").arg(QString::fromStdString(ec.message())));

    resumeData.sharedContentPathSignature = fromLTString(
            resumeDataRoot.dict_find_string_value("qBt-sharedContentPathSignature"));

    lt::add_torrent_params &p = resumeData.ltAddTorrentParams;]=]
"SQLite shared-path resume-data load")

qbt_replace_exact(db_resume_data
[=[        lt::entry data = lt::write_resume_data(p);

        // metadata is stored in separate column]=]
[=[        lt::entry data = lt::write_resume_data(p);
        data["qBt-sharedContentPathSignature"] = m_resumeData.sharedContentPathSignature.toStdString();

        // metadata is stored in separate column]=]
"SQLite shared-path resume-data store")

get_filename_component(db_resume_output_dir "${QBT_DBRESUMEDATA_OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${db_resume_output_dir}")
file(WRITE "${QBT_DBRESUMEDATA_OUTPUT}" "${db_resume_data}")
