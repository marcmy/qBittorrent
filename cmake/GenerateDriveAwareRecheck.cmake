# Add drive-aware Force Recheck scheduling on top of the generated TorrentImpl.
# Keep at most one active full check per physical Windows disk while allowing
# independent disks to check concurrently. On other platforms, group by the
# mounted storage device reported by QStorageInfo.

if (NOT DEFINED QBT_TORRENTIMPL_OUTPUT)
    message(FATAL_ERROR "GenerateDriveAwareRecheck: QBT_TORRENTIMPL_OUTPUT is not defined")
endif()

file(READ "${QBT_TORRENTIMPL_OUTPUT}" torrent_impl)

qbt_replace_exact(torrent_impl
[=[#ifdef Q_OS_WIN
#include <windows.h>
#endif]=]
[=[#ifdef Q_OS_WIN
#include <windows.h>
#include <winioctl.h>
#endif]=]
"drive-aware Windows volume include")

qbt_replace_exact(torrent_impl
[=[#include <algorithm>
#include <memory>]=]
[=[#include <algorithm>
#include <memory>
#include <vector>]=]
"drive-aware standard includes")

qbt_replace_exact(torrent_impl
[=[#include <QDebug>
#include <QFuture>]=]
[=[#include <QDebug>
#include <QDir>
#include <QFuture>
#include <QHash>
#include <QQueue>]=]
"drive-aware Qt container includes")

qbt_replace_exact(torrent_impl
[=[#include <QSet>
#include <QStringList>]=]
[=[#include <QSet>
#include <QStorageInfo>
#include <QStringList>]=]
"drive-aware storage include")

qbt_replace_exact(torrent_impl
[=[    PathList makeCollisionSafeFilePaths(const PathList &filePaths, const QString &suffix)
]=]
[=[    QString recheckStorageDeviceKey(const Torrent *torrent)
    {
        Path storageLocation = torrent->actualStorageLocation();
        if (storageLocation.isEmpty())
            storageLocation = torrent->savePath();

        const QString storagePath = storageLocation.toString();

#ifdef Q_OS_WIN
        const std::wstring nativePath = QDir::toNativeSeparators(storagePath).toStdWString();
        wchar_t volumePath[MAX_PATH] {};
        if (!nativePath.empty() && ::GetVolumePathNameW(nativePath.c_str(), volumePath, MAX_PATH))
        {
            wchar_t volumeName[MAX_PATH] {};
            if (::GetVolumeNameForVolumeMountPointW(volumePath, volumeName, MAX_PATH))
            {
                std::wstring volumeDevice {volumeName};
                while (!volumeDevice.empty() && ((volumeDevice.back() == L'\\') || (volumeDevice.back() == L'/')))
                    volumeDevice.pop_back();

                const HANDLE volumeHandle = ::CreateFileW(volumeDevice.c_str(), 0
                        , FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE
                        , nullptr, OPEN_EXISTING, 0, nullptr);
                if (volumeHandle != INVALID_HANDLE_VALUE)
                {
                    // 64 KiB accommodates far more extents than a normal basic volume.
                    std::vector<char> extentBuffer(64 * 1024);
                    DWORD bytesReturned = 0;
                    const BOOL ok = ::DeviceIoControl(volumeHandle, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS
                            , nullptr, 0, extentBuffer.data(), static_cast<DWORD>(extentBuffer.size())
                            , &bytesReturned, nullptr);
                    ::CloseHandle(volumeHandle);

                    if (ok && (bytesReturned >= sizeof(VOLUME_DISK_EXTENTS)))
                    {
                        const auto *extents = reinterpret_cast<const VOLUME_DISK_EXTENTS *>(extentBuffer.data());
                        QStringList diskNumbers;
                        diskNumbers.reserve(static_cast<qsizetype>(extents->NumberOfDiskExtents));
                        for (DWORD i = 0; i < extents->NumberOfDiskExtents; ++i)
                            diskNumbers.append(QString::number(extents->Extents[i].DiskNumber));

                        std::sort(diskNumbers.begin(), diskNumbers.end());
                        diskNumbers.removeDuplicates();
                        if (!diskNumbers.isEmpty())
                            return u"physical-disk:"_s + diskNumbers.join(u',');
                    }
                }

                return u"volume:"_s + QString::fromWCharArray(volumeName).toCaseFolded();
            }

            return u"volume-root:"_s + QString::fromWCharArray(volumePath).toCaseFolded();
        }
#endif

        const QStorageInfo storageInfo {storagePath};
        if (storageInfo.isValid() && storageInfo.isReady())
        {
            if (!storageInfo.device().isEmpty())
                return u"storage:"_s + QString::fromUtf8(storageInfo.device());
            if (!storageInfo.rootPath().isEmpty())
                return u"root:"_s + storageInfo.rootPath().toCaseFolded();
        }

        return u"path:"_s + storagePath.toCaseFolded();
    }

    struct DriveAwareRecheckState
    {
        bool originalLimitCaptured = false;
        int originalLimit = 1;
        int lastAppliedLimit = 1;
        QHash<QString, QPointer<Torrent>> activeByDevice;
        QHash<QString, QQueue<QPointer<Torrent>>> pendingByDevice;
        QHash<Torrent *, QString> scheduledDevices;
        QSet<Torrent *> dispatching;
        QMetaObject::Connection finishedConnection;
        QMetaObject::Connection removedConnection;
    };

    QHash<Session *, DriveAwareRecheckState> driveAwareRecheckStates;

    void finishDriveAwareRecheck(Torrent *torrent);
    void removeDriveAwareRecheck(Torrent *torrent);

    void applyDriveAwareCheckingLimit(Session *session, DriveAwareRecheckState &state)
    {
        const int desiredLimit = std::max(state.originalLimit, static_cast<int>(state.activeByDevice.size()));
        if (session->maxActiveCheckingTorrents() != desiredLimit)
            session->setMaxActiveCheckingTorrents(desiredLimit);
        state.lastAppliedLimit = desiredLimit;
    }

    void ensureDriveAwareRecheckState(Session *session, DriveAwareRecheckState &state)
    {
        if (state.originalLimitCaptured)
            return;

        state.originalLimitCaptured = true;
        state.originalLimit = session->maxActiveCheckingTorrents();
        state.lastAppliedLimit = state.originalLimit;
        state.finishedConnection = QObject::connect(session, &Session::torrentFinishedChecking, session
                , [](Torrent *torrent) { finishDriveAwareRecheck(torrent); });
        state.removedConnection = QObject::connect(session, &Session::torrentAboutToBeRemoved, session
                , [](Torrent *torrent) { removeDriveAwareRecheck(torrent); });
    }

    bool consumeDriveAwareRecheckDispatch(Torrent *torrent)
    {
        const auto stateIt = driveAwareRecheckStates.find(torrent->session());
        if (stateIt == driveAwareRecheckStates.end())
            return false;

        return stateIt->dispatching.remove(torrent) > 0;
    }

    void dispatchDriveAwareRecheck(Torrent *torrent)
    {
        auto stateIt = driveAwareRecheckStates.find(torrent->session());
        if (stateIt == driveAwareRecheckStates.end())
            return;

        stateIt->dispatching.insert(torrent);
        torrent->forceRecheck();
    }

    void startNextDriveAwareRecheck(Session *session, DriveAwareRecheckState &state, const QString &deviceKey)
    {
        auto queueIt = state.pendingByDevice.find(deviceKey);
        if (queueIt == state.pendingByDevice.end())
            return;

        while (!queueIt->isEmpty())
        {
            const QPointer<Torrent> next = queueIt->dequeue();
            if (next.isNull() || !state.scheduledDevices.contains(next.data()))
                continue;

            state.activeByDevice.insert(deviceKey, next);
            applyDriveAwareCheckingLimit(session, state);
            dispatchDriveAwareRecheck(next.data());
            break;
        }

        if (queueIt->isEmpty())
            state.pendingByDevice.erase(queueIt);
    }

    void cleanupDriveAwareRecheckState(Session *session)
    {
        auto stateIt = driveAwareRecheckStates.find(session);
        if (stateIt == driveAwareRecheckStates.end())
            return;

        DriveAwareRecheckState &state = stateIt.value();
        if (!state.scheduledDevices.isEmpty() || !state.activeByDevice.isEmpty())
        {
            applyDriveAwareCheckingLimit(session, state);
            return;
        }

        // Do not overwrite a setting the user changed while the batch was running.
        if (session->maxActiveCheckingTorrents() == state.lastAppliedLimit
                && state.lastAppliedLimit != state.originalLimit)
        {
            session->setMaxActiveCheckingTorrents(state.originalLimit);
        }

        QObject::disconnect(state.finishedConnection);
        QObject::disconnect(state.removedConnection);
        driveAwareRecheckStates.erase(stateIt);
    }

    void scheduleDriveAwareRecheck(Torrent *torrent)
    {
        Session *const session = torrent->session();
        DriveAwareRecheckState &state = driveAwareRecheckStates[session];
        ensureDriveAwareRecheckState(session, state);

        if (state.scheduledDevices.contains(torrent))
            return;

        const QString deviceKey = recheckStorageDeviceKey(torrent);
        state.scheduledDevices.insert(torrent, deviceKey);

        const QPointer<Torrent> active = state.activeByDevice.value(deviceKey);
        if (active.isNull())
        {
            state.activeByDevice.insert(deviceKey, torrent);
            applyDriveAwareCheckingLimit(session, state);
            dispatchDriveAwareRecheck(torrent);
        }
        else
        {
            state.pendingByDevice[deviceKey].enqueue(torrent);
        }
    }

    void finishDriveAwareRecheck(Torrent *torrent)
    {
        Session *const session = torrent->session();
        auto stateIt = driveAwareRecheckStates.find(session);
        if (stateIt == driveAwareRecheckStates.end())
            return;

        DriveAwareRecheckState &state = stateIt.value();
        const auto scheduledIt = state.scheduledDevices.find(torrent);
        if (scheduledIt == state.scheduledDevices.end())
            return;

        const QString deviceKey = scheduledIt.value();
        state.scheduledDevices.erase(scheduledIt);
        state.dispatching.remove(torrent);

        if (state.activeByDevice.value(deviceKey).data() == torrent)
        {
            state.activeByDevice.remove(deviceKey);
            startNextDriveAwareRecheck(session, state, deviceKey);
        }

        cleanupDriveAwareRecheckState(session);
    }

    void removeDriveAwareRecheck(Torrent *torrent)
    {
        Session *const session = torrent->session();
        auto stateIt = driveAwareRecheckStates.find(session);
        if (stateIt == driveAwareRecheckStates.end())
            return;

        DriveAwareRecheckState &state = stateIt.value();
        const auto scheduledIt = state.scheduledDevices.find(torrent);
        if (scheduledIt == state.scheduledDevices.end())
            return;

        const QString deviceKey = scheduledIt.value();
        state.scheduledDevices.erase(scheduledIt);
        state.dispatching.remove(torrent);

        auto queueIt = state.pendingByDevice.find(deviceKey);
        if (queueIt != state.pendingByDevice.end())
        {
            QQueue<QPointer<Torrent>> retained;
            while (!queueIt->isEmpty())
            {
                const QPointer<Torrent> item = queueIt->dequeue();
                if (!item.isNull() && (item.data() != torrent))
                    retained.enqueue(item);
            }
            *queueIt = std::move(retained);
            if (queueIt->isEmpty())
                state.pendingByDevice.erase(queueIt);
        }

        if (state.activeByDevice.value(deviceKey).data() == torrent)
        {
            state.activeByDevice.remove(deviceKey);
            startNextDriveAwareRecheck(session, state, deviceKey);
        }

        cleanupDriveAwareRecheckState(session);
    }

    PathList makeCollisionSafeFilePaths(const PathList &filePaths, const QString &suffix)
]=]
"drive-aware recheck scheduler insertion")

qbt_replace_exact(torrent_impl
[=[void TorrentImpl::forceRecheck()
{
    if (!hasMetadata())
        return;

    m_nativeHandle.force_recheck();]=]
[=[void TorrentImpl::forceRecheck()
{
    if (!hasMetadata())
        return;

    // The scheduler calls back through this method to keep the public Torrent
    // interface as the single dispatch path. Only that marked re-entry reaches
    // libtorrent directly; external requests are grouped by physical storage.
    if (!consumeDriveAwareRecheckDispatch(this))
    {
        scheduleDriveAwareRecheck(this);
        return;
    }

    m_nativeHandle.force_recheck();]=]
"drive-aware force-recheck dispatch")

file(WRITE "${QBT_TORRENTIMPL_OUTPUT}" "${torrent_impl}")
