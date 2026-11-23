set -eu
C=/root/r12-engine-offline
bash "$C/r12-engine-services204.sh" dns-stop
trap 'bash "$C/r12-engine-services204.sh" dns-start' EXIT
timeout 30 ip netns exec r12-lan /usr/bin/python3 "$C/r12-engine-probe204.py" r12e-t8-$(date +%s) VPN
bash "$C/r12-engine-services204.sh" dns-start
trap - EXIT
timeout 30 ip netns exec r12-lan /usr/bin/python3 "$C/r12-engine-probe204.py" r12e-t8-restored-$(date +%s) VPN
