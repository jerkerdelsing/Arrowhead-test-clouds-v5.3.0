# SPDX-License-Identifier: EPL-2.0
# Go test cloud v5.3.0 (2026-11-11): a primary-source Go image plus this cloud's deployment helpers (v530/build.sh):
# the health probe ah-probe, and ah-lcm-launcher (used only by LocalCloudManager, see v530/console/launcher).
# The primary images are scratch images without /state or /data: a new named volume mounted there would belong to root,
# and the systems run as 65532. Empty directories owned by 65532 make Docker initialise the volumes with that owner.
ARG BASE
FROM ${BASE}
COPY bin/ah-probe bin/ah-lcm-launcher /usr/local/bin/
COPY --chown=65532:65532 empty/ /state/
COPY --chown=65532:65532 empty/ /data/
