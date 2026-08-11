# Compose fork-specific source transforms in stable layers.
# The base generator preserves the existing custom torrent/resume behavior;
# additional transforms can operate on its generated output without rewriting it.

include("${CMAKE_CURRENT_LIST_DIR}/GenerateCustomTorrentSourcesBase.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/GenerateDriveAwareRecheck.cmake")
