# Add cancelable Force Recheck behavior on top of the drive-aware generated TorrentImpl.
# A second Force Recheck request cancels either the queued request or the active check,
# restoring the torrent state captured immediately before libtorrent started rechecking.

if (NOT DEFINED QBT_TORRENTIMPL_OUTPUT)
    message(FATAL_ERROR "GenerateCancelableForceRecheck: QBT_TORRENTIMPL_OUTPUT is not defined")
endif()

file(READ "${QBT_TORRENTIMPL_OUTPUT}" torrent_impl)

qbt_replace_exact(torrent_impl
[=[#include <algorithm>
#include <memory>
#include <vector>]=]
[=[#include <algorithm>
#include <map>
#include <memory>
#include <vector>]=]
"std::map include for force-recheck snapshots")

qbt_replace_exact(torrent_impl
[=[using namespace BitTorrent;

namespace
{]=]
[=[using namespace BitTorrent;

namespace
{
    struct ForceRecheckSnapshot
    {
        lt::add_torrent_params resumeData;
        lt::queue_position_t queuePosition;
    };

    std::map<const TorrentImpl *, ForceRecheckSnapshot> forceRecheckSnapshots;]=]
"force-recheck snapshot storage")

qbt_replace_exact(torrent_impl
[=[TorrentImpl::~TorrentImpl() = default;]=]
[=[TorrentImpl::~TorrentImpl()
{
    forceRecheckSnapshots.erase(this);
}]=]
"force-recheck snapshot cleanup on destruction")

qbt_replace_exact(torrent_impl
[=[    void scheduleDriveAwareRecheck(Torrent *torrent)
    {]=]
[=[    bool cancelDriveAwareRecheck(Torrent *torrent)
    {
        Session *const session = torrent->session();
        auto stateIt = driveAwareRecheckStates.find(session);
        if (stateIt == driveAwareRecheckStates.end())
            return false;

        DriveAwareRecheckState &state = stateIt.value();
        const auto scheduledIt = state.scheduledDevices.find(torrent);
        if (scheduledIt == state.scheduledDevices.end())
            return false;

        QString deviceKey = scheduledIt.value();
        state.scheduledDevices.erase(scheduledIt);

        const bool wasActiveScheduled = state.activeScheduled.contains(torrent);
        state.activeScheduled.remove(torrent);
        state.dispatching.remove(torrent);

        if (wasActiveScheduled)
        {
            const auto activeIt = state.activeDevices.find(torrent);
            if (activeIt != state.activeDevices.end())
            {
                deviceKey = activeIt.value();
                state.activeDevices.erase(activeIt);
            }
        }

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

        if (wasActiveScheduled && !hasActiveDriveAwareRecheck(state, deviceKey))
            deferNextDriveAwareRecheck(session, deviceKey);

        cleanupDriveAwareRecheckState(session);
        return true;
    }

    void scheduleDriveAwareRecheck(Torrent *torrent)
    {]=]
"drive-aware recheck cancellation helper")

qbt_replace_exact(torrent_impl
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
[=[void TorrentImpl::forceRecheck()
{
    if (!hasMetadata())
        return;

    // A scheduler dispatch is the only path that is allowed to reach
    // libtorrent. External calls either queue a new check or toggle an
    // already queued/active forced recheck off.
    if (!consumeDriveAwareRecheckDispatch(this))
    {
        if (const auto snapshotIter = forceRecheckSnapshots.find(this); snapshotIter != forceRecheckSnapshots.end())
        {
            auto snapshot = std::move(snapshotIter->second);
            forceRecheckSnapshots.erase(snapshotIter);
            cancelDriveAwareRecheck(this);

            m_ltAddTorrentParams = std::move(snapshot.resumeData);
            reload();

            if (snapshot.queuePosition >= lt::queue_position_t {})
                m_nativeHandle.queue_position_set(snapshot.queuePosition);
            m_nativeStatus.queue_position = snapshot.queuePosition;

            deferredRequestResumeData();
            LogMsg(tr("Canceled force recheck and restored the torrent's previous state. Torrent: \"%1\"").arg(name()));
            return;
        }

        if (cancelDriveAwareRecheck(this))
        {
            LogMsg(tr("Canceled queued force recheck. Torrent: \"%1\"").arg(name()));
            return;
        }

        if ((m_nativeStatus.state == lt::torrent_status::checking_resume_data)
                || (m_nativeStatus.state == lt::torrent_status::checking_files))
        {
            return;
        }

        scheduleDriveAwareRecheck(this);
        return;
    }

    // The torrent may have entered a non-forced checking state while it was
    // queued behind another torrent on the same device. Do not overwrite that
    // state with a new forced check; release the scheduler slot instead.
    if ((m_nativeStatus.state == lt::torrent_status::checking_resume_data)
            || (m_nativeStatus.state == lt::torrent_status::checking_files))
    {
        cancelDriveAwareRecheck(this);
        return;
    }

    forceRecheckSnapshots.emplace(this, ForceRecheckSnapshot
    {
        m_nativeHandle.get_resume_data(),
        m_nativeHandle.queue_position()
    });

    m_nativeHandle.force_recheck();]=]
"cancelable drive-aware force-recheck implementation")

qbt_replace_exact(torrent_impl
[=[void TorrentImpl::handleTorrentChecked()
{
    if (!hasMetadata())]=]
[=[void TorrentImpl::handleTorrentChecked()
{
    forceRecheckSnapshots.erase(this);

    if (!hasMetadata())]=]
"force-recheck snapshot cleanup after completion")

file(WRITE "${QBT_TORRENTIMPL_OUTPUT}" "${torrent_impl}")
