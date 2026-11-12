#!/bin/sh
# The Java DataManager's dataHistorian policy covers RandomDataProducer and LocalCloudManager.
set -eu
exec "$(dirname -- "$0")/configure-datamanager-policies.sh"
