#!/bin/bash
# Test reversible Stage6 EDNS compatibility patch, after Stage7 services rollback.
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"
set -Eeuo pipefail
S=/root/r12-stage6
B=/root/r12-engine-baseline204
[[ $EUID == 0 && $(ip -o link show | wc -l) == 1 ]]
[[ ! -e $B/fixture.edns-validated.py && ! -e $B/assets.edns-validated.sha256 ]]
bash "$S/control.sh" verify >/dev/null
cp -p "$S/fixture.py" "$B/fixture.edns-validated.py"
cp -p "$S/assets.sha256" "$B/assets.edns-validated.sha256"
bash "$S/control.sh" stop
cp -p "$B/fixture.stage6-before-edns.py" "$S/fixture.py"
cp -p "$B/assets.stage6-before-edns.sha256" "$S/assets.sha256"
bash "$S/control.sh" start
sh "$S/probe.sh"
echo ORIGINAL_STAGE6_FIXTURE_ROLLBACK_TRANSIT_PASS
bash "$S/control.sh" stop
cp -p "$B/fixture.edns-validated.py" "$S/fixture.py"
cp -p "$B/assets.edns-validated.sha256" "$S/assets.sha256"
bash "$S/control.sh" start
sh "$S/probe.sh"
echo EDNS_FIXTURE_REAPPLY_TRANSIT_PASS
