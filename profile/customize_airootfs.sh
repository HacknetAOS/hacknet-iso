#!/bin/bash
# Deprecated top-level customize_airootfs.sh.
# The real work happens in airootfs/root/customize_airootfs.sh, which mkarchiso
# executes. This file is kept only so the profile stays compatible; it must not
# fail the build.

set -uo pipefail
echo "=== (profile-level customize_airootfs.sh) nothing to do ==="
exit 0
