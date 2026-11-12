#!/bin/sh
# DataManager's sysMonitor policy is one of the sysMonitor policies owned by configure-all-sysmonitor-policies.sh;
# this target is kept for the Makefile and applies all of them.
set -eu
exec "$(dirname -- "$0")/configure-all-sysmonitor-policies.sh"
