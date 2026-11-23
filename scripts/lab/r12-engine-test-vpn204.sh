set -eu
C=/root/r12-engine-offline
bash "$C/r12-engine-services204.sh" vpn-stop
trap 'bash "$C/r12-engine-services204.sh" vpn-start' EXIT
sleep 15
timeout 8 ip netns exec r12-lan /usr/bin/python3 "$C/r12-engine-probe204.py" r12e-t5-$(date +%s) DIRECT
bash "$C/r12-engine-services204.sh" vpn-start
trap - EXIT
r12_start=$(date +%s)
for n in 1 2 3; do
 sleep 5
 if timeout 8 ip netns exec r12-lan /usr/bin/python3 "$C/r12-engine-probe204.py" r12e-t6-$(date +%s) VPN; then
  echo "AUTOMATIC_RECOVERY_SECONDS=$(($(date +%s)-r12_start))"; exit 0
 fi
done
exit 1
