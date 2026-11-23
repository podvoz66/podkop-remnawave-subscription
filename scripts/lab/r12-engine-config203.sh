#!/bin/sh
# Synthetic lab configuration; no production data. Never prints the UUID/config.
set -eu
umask 077
[ "$(cat /sys/class/net/eth0/address)" = 02:52:12:02:03:01 ]
[ "$(cat /sys/class/net/eth1/address)" = 02:52:12:02:03:02 ]
[ -z "$(ip -4 route show default)" ]
[ -z "$(uci -q changes)" ]
S=/root/r12-engine-runtime
[ ! -e "$S" ]
mkdir -m 700 "$S"
cp /etc/config/podkop "$S/podkop.package-default"
cp /etc/config/sing-box "$S/sing-box.package-default"
wget -q -O "$S/ca.crt" http://10.253.203.1:8001/ca.crt
curl --fail --silent --show-error --cacert "$S/ca.crt" https://10.253.203.1:8002/uuid -o "$S/uuid"
chmod 600 "$S/uuid"
uuid=$(cat "$S/uuid")
printf '%s' "$uuid" | grep -Eq '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
uci -q delete network.wan.dns || true
uci add_list network.wan.dns=10.253.203.1
uci set network.wan.peerdns=0
uci set 'dhcp.@dnsmasq[0].noresolv=1'
uci -q delete 'dhcp.@dnsmasq[0].server' || true
uci add_list 'dhcp.@dnsmasq[0].server=10.253.203.1'
uci set podkop.settings.dns_type=udp
uci set podkop.settings.dns_server=10.253.203.1:5353
uci set podkop.settings.bootstrap_dns_server=10.253.203.1
uci set podkop.settings.dont_touch_dhcp=0
uci set podkop.settings.enable_utls_fallback=0
uci set podkop.settings.log_level=info
uci -q delete podkop.main.community_lists || true
uci set podkop.main.connection_type=proxy
uci set podkop.main.proxy_config_type=outbound
group='{"type":"urltest","outbounds":["vpn-out"],"fallbacks":["direct-out"],"url":"http://10.253.203.1:8001/probe64k","download_url":"http://10.253.203.1:8001/probe64k","interval":"10s","tolerance":0}'
uci set "podkop.main.outbound_json=$group"
uci set podkop.main.user_domain_list_type=dynamic
uci add_list podkop.main.user_domains=vpn.r12.test
uci add_list podkop.main.user_domains=vptcp.r12.test
uci set podkop.main.user_subnet_list_type=dynamic
uci add_list podkop.main.user_subnets=10.253.203.1/32
uci set podkop.USA=section
uci set podkop.USA.connection_type=proxy
uci set podkop.USA.proxy_config_type=outbound
uci set "podkop.USA.outbound_json=$group"
uci set podkop.USA.user_domain_list_type=dynamic
uci add_list podkop.USA.user_domains=usa.r12.test
uci set podkop.vpn=section
uci set podkop.vpn.connection_type=proxy
uci set podkop.vpn.proxy_config_type=outbound
outbound=$(jq -cn --arg uuid "$uuid" --arg cert "$S/ca.crt" '{type:"vless",server:"10.253.203.1",server_port:10443,uuid:$uuid,packet_encoding:"",tls:{enabled:true,server_name:"fixture.r12.test",certificate_path:$cert}}')
uci set "podkop.vpn.outbound_json=$outbound"
unset uuid outbound
uci set sing-box.main.urltest_download_url=http://10.253.203.1:8001/probe64k
for config in network dhcp podkop sing-box; do uci commit "$config"; done
/etc/init.d/network reload
/etc/init.d/dnsmasq restart
cp /etc/config/podkop "$S/podkop.good"
cp /etc/config/dhcp "$S/dhcp.direct"
cp /etc/config/network "$S/network.good"
# OpenWrt's RFC6761 config returns NXDOMAIN for .test. Only this LAB fixture
# suffix uses normal upstreams (#) and may return its private synthetic IP.
cp /etc/dnsmasq.conf "$S/dnsmasq.conf.before-fixture"
printf '\n# R12 isolated fixture only\nserver=/r12.test/#\nrebind-domain-ok=/r12.test/\n' >> /etc/dnsmasq.conf
/etc/init.d/dnsmasq restart
/etc/init.d/podkop restart
sleep 5
sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1
pid=$(ubus call service list '{"name":"sing-box"}' | jsonfilter -e '@["sing-box"].instances["sing-box.main"].pid')
[ -n "$pid" ] && kill -0 "$pid"
dig +short +timeout=3 +tries=1 @127.0.0.42 fakeip.podkop.fyi | grep -Eq '^198\.1[89]\.'
nft list table inet PodkopTable >/dev/null
ip rule | grep -q 'lookup podkop'
echo ENGINE_LAB_CONFIG_STARTED_NOT_YET_TRANSIT_ACCEPTED
