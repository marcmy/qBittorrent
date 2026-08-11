# Compose fork-specific source transforms in stable layers.
# The base generator preserves the existing custom torrent/resume behavior.
#
# NOTE: Drive-aware Force Recheck scheduling is intentionally disabled here.
# The first runtime implementation could leave checks running after torrents
# were stopped and could advance same-device work before the prior native check
# had actually quiesced. Keep normal qBittorrent/libtorrent recheck semantics
# until the scheduler is redesigned around authoritative native check activity.

include("${CMAKE_CURRENT_LIST_DIR}/GenerateCustomTorrentSourcesBase.cmake")
