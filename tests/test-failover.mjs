import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec=promisify(execFile);
const repo=path.resolve(import.meta.dirname,'..');
const runtime=process.env.OPENWRT_RUNTIME;
if(!runtime) throw Error('Set OPENWRT_RUNTIME to local fixture directory (see docs/fail-open.ru.md)');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'podkop-tests-'));
const lib=path.join(repo,'scripts/podkop-failover-lib.sh');
const updater=path.join(repo,'scripts/update-podkop-from-remnawave.sh');
const ash=runtime+'/bin/ash';
const uuid='11111111-1111-4111-8111-111111111111';
const badUuid='22222222-2222-4222-8222-222222222222';
let requests=0, peer, httpServer, httpsServer;
let subscriptionBody='';
after(async()=>{
  if(peer && peer.exitCode===null){peer.kill(); await new Promise(r=>peer.once('exit',r));}
  for(const s of [httpServer,httpsServer]) if(s) {s.closeAllConnections();await new Promise(r=>s.close(r));}
  fs.rmSync(temp,{recursive:true,force:true});
});
const write=(p,s)=>{fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,s,{mode:0o700});};
const listen=s=>new Promise(r=>s.listen(0,'127.0.0.1',()=>r(s.address().port)));
async function setupNetwork(){
  httpServer=http.createServer((q,r)=>{requests++;r.writeHead(204);r.end();});
  const hp=await listen(httpServer);
  await exec('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-keyout',temp+'/key.pem','-out',temp+'/cert.pem','-days','1','-subj','/CN=127.0.0.1','-addext','subjectAltName=IP:127.0.0.1']);
  httpsServer=https.createServer({key:fs.readFileSync(temp+'/key.pem'),cert:fs.readFileSync(temp+'/cert.pem')},(q,r)=>{
    requests++;
    if(q.url==='/subscription'){r.writeHead(200);r.end(subscriptionBody);}
    else if(q.url==='/unavailable'){r.writeHead(503);r.end('unavailable');}
    else {r.writeHead(204);r.end();}
  });
  const sp=await listen(httpsServer);
  const socket=net.createServer(); const vp=await listen(socket);await new Promise(r=>socket.close(r));
  write(temp+'/peer.json',JSON.stringify({log:{disabled:true},inbounds:[{type:'vless',tag:'test-peer',listen:'127.0.0.1',listen_port:vp,users:[{uuid}]}],outbounds:[{type:'direct',tag:'direct'}]}));
  peer=spawn(runtime+'/bin/sing-box',['run','-c',temp+'/peer.json'],{stdio:'ignore'});
  await new Promise(r=>setTimeout(r,400));
  return {hp,sp,vp};
}
const network=await setupNetwork();
const link=(name,id=uuid)=>`vless://${id}@127.0.0.1:${network.vp}#${name}`;
function fixture(){
  const root=fs.mkdtempSync(temp+'/root-');
  const cfg=root+'/etc/config';
  write(cfg+'/podkop',`config settings 'settings'\n option dont_touch_dhcp '1'\nconfig section 'main'\n option connection_type 'proxy'\n option proxy_config_type 'urltest'\n list urltest_proxy_links '${link('old-main-rwsub')}'\n list urltest_proxy_links '${link('manual-main')}'\nconfig section 'USA'\n option connection_type 'proxy'\n option proxy_config_type 'urltest'\n list urltest_proxy_links '${link('us-old-rwsub')}'\nconfig section 'unrelated'\n option interface 'zt-safe'\n`);
  write(cfg+'/dhcp',"config dnsmasq\n list server '127.0.0.42'\n option noresolv '1'\n option cachesize '0'\nconfig dhcp 'lan'\n option interface 'br-lan'\n");
  write(root+'/etc/sing-box/config.json','{"outbounds":[{"type":"direct"}]}');
  write(root+'/etc/podkop-remnawave/subscription.conf',"SUB_URL='https://subscription.invalid/SECRET_SUBSCRIPTION'\n");
  write(root+'/body',link('new-main')+'\n'+link('us-direct-reality')+'\n');
  write(root+'/etc/podkop-failover/normal-dns/dhcp',fs.readFileSync(cfg+'/dhcp','utf8'));
  fs.mkdirSync(root+'/etc/podkop-failover/normal-dns/.uci');
  fs.mkdirSync(cfg+'/.uci');
  fs.mkdirSync(root+'/tmp/podkop-failover',{recursive:true});
  write(root+'/tmp/podkop-failover/mode','NORMAL\n');
  const bin=root+'/bin';
  // Only these kernel/service boundaries are mocked. UCI, parser, check, shadow
  // sing-box, VLESS peer, SOCKS, HTTP, HTTPS and TLS validation are real.
  write(bin+'/curl',`#!/bin/sh
for a in "$@"; do
 case "$a" in
 --config) [ ! -f "$PODKOP_ROOT/download-fail" ] || exit 22; download=1;;
 --interface) [ ! -f "$PODKOP_ROOT/wan-fail" ] || exit 7;;
 *'/proxies/USA-out/'*) [ ! -f "$PODKOP_ROOT/api-USA-fail" ] || exit 7; [ ! -f "$PODKOP_ROOT/api-fail" ] || exit 7; echo '{"delay":12}'; exit 0;;
 *'/proxies/'*) [ ! -f "$PODKOP_ROOT/api-fail" ] || exit 7; echo '{"delay":12}'; exit 0;;
 esac
done
if [ "$download" = 1 ] && [ ! -f "$PODKOP_ROOT/real-download" ]; then
 while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; cp "$PODKOP_ROOT/body" "$1"; exit; fi; shift; done
 exit 2
fi
exec /usr/bin/curl "$@"
`);
  write(bin+'/pgrep','#!/bin/sh\n[ ! -f "$PODKOP_ROOT/process-fail" ]\n');
  write(bin+'/nslookup',`#!/bin/sh
[ ! -f "$PODKOP_ROOT/direct-dns-fail" ] || exit 1
if [ -f "$PODKOP_ROOT/dns-fail" ] && grep -q 127.0.0.42 "$PODKOP_ROOT/etc/config/dhcp"; then exit 1; fi
echo "Address: 198.18.0.1"
`);
  write(bin+'/logger','#!/bin/sh\nexit 0\n');
  write(bin+'/sync','#!/bin/sh\nexit 0\n');
  write(bin+'/nft',`#!/bin/sh
echo "nft $*" >> "$PODKOP_ROOT/actions"
case "$*" in
 'delete table inet PodkopTable') [ ! -f "$PODKOP_ROOT/remove-fail" ] || exit 1;;
 'delete table inet podkop_failopen') [ ! -f "$PODKOP_ROOT/unblock-fail" ] || exit 1;;
 '-f -') [ ! -f "$PODKOP_ROOT/block-fail" ] || exit 1;;
esac
case "$*" in
 'list table inet podkop_failopen') test -f "$PODKOP_ROOT/fakeip-block";;
 'list table inet PodkopTable') echo tproxy; exit 0;;
 'delete table inet podkop_failopen') rm -f "$PODKOP_ROOT/fakeip-block";;
 '-f -') cat > "$PODKOP_ROOT/nft-input"; touch "$PODKOP_ROOT/fakeip-block";;
esac
`);
  write(bin+'/ip',`#!/bin/sh
echo "ip $*" >> "$PODKOP_ROOT/actions"
case "$*" in
 '-4 rule show') [ -f "$PODKOP_ROOT/rules-removed" ] || echo '105: from all fwmark 0x100000/0x100000 lookup podkop'; echo '32766: from all lookup main'; echo '52: from all lookup 52';;
 '-4 rule del priority 105 fwmark 0x100000/0x100000 table podkop') touch "$PODKOP_ROOT/rules-removed";;
 '-4 route show table podkop') echo 'local default dev lo scope host';;
esac
`);
  for(const svc of ['podkop','dnsmasq','sing-box'])write(root+'/etc/init.d/'+svc,`#!/bin/sh
echo '${svc}' "$@" >> "$PODKOP_ROOT/actions"
if [ '${svc}' = dnsmasq ] && [ -f "$PODKOP_ROOT/restart-fail" ]; then exit 1; fi
if [ '${svc}' = podkop ] && [ "$1" = start ] && [ -f "$PODKOP_ROOT/start-fail" ]; then exit 1; fi
if [ '${svc}' = podkop ] && [ "$1" = start ]; then rm -f "$PODKOP_ROOT/rules-removed"; fi
exit 0
`);
  const env={...process.env,PATH:bin+':'+runtime+'/bin:'+process.env.PATH,PODKOP_ROOT:root,GUARD_LIB:lib,
    PODKOP_FUNCTIONS:runtime+'/functions.sh',PODKOP_CONSTANTS:runtime+'/constants.sh',PODKOP_FACADE:runtime+'/facade-local.sh',
    PROBE_URLS:`https://127.0.0.1:${network.sp}/ http://127.0.0.1:${network.hp}/`,CURL_CA_BUNDLE:temp+'/cert.pem',
    PROBE_MARK:'0',PROBE_SECONDS:'1',COOLDOWN:'0',WAN_DEVICE:'lo'};
  return {root,cfg,env};
}
async function shell(f,code){return exec(ash,['-c',`. '${lib}'; guard_setup; ${code}`],{env:f.env,timeout:45000});}
async function update(f,args=[]){try{return {ok:true,...await exec(ash,[updater,...args],{env:f.env,timeout:45000})};}catch(e){return {ok:false,stdout:e.stdout,stderr:e.stderr};}}
const read=(f,p)=>fs.readFileSync(f.root+p,'utf8');
test('local native runtime can dial a loopback origin',async()=>{
  const f=fixture();await shell(f,`make_probe_config "$CFG" "$RUN/debug.json"`);
  const p=spawn(runtime+'/bin/sing-box',['run','-c',f.root+'/tmp/podkop-failover/debug.json','-D',f.root+'/tmp'],{env:f.env,stdio:['ignore','ignore','pipe']});
  let errors='';p.stderr.on('data',c=>errors+=c);await new Promise(r=>setTimeout(r,400));
  try {
    assert.equal(p.exitCode,null,errors);
    const result=await exec('/usr/bin/curl',['-v','--noproxy','','--proxy','socks5h://127.0.0.1:17890','--max-time','3',`http://127.0.0.1:${network.hp}/`],{env:f.env});
    assert.match(result.stderr,/204/);
  } finally {if(p.exitCode===null){p.kill();await new Promise(r=>p.once('exit',r));}}
});
test('empty USA rejects transaction without changing working keys',async()=>{
  const f=fixture(),before=read(f,'/etc/config/podkop');write(f.root+'/body',link('new-main')+'\n');
  const r=await update(f);assert.equal(r.ok,false);assert.match(r.stderr,/section empty/);
  assert.equal(read(f,'/etc/config/podkop'),before);assert.ok(!fs.existsSync(f.root+'/actions'));
});
test('corrupt subscription and HTTP failure retain previous keys without secrets in logs',async()=>{
  for(const type of ['corrupt','unavailable']){
    const f=fixture(),before=read(f,'/etc/config/podkop');
    if(type==='corrupt')write(f.root+'/body','<html>SECRET_SUBSCRIPTION</html>');else write(f.root+'/download-fail','');
    const r=await update(f);assert.equal(r.ok,false);assert.equal(read(f,'/etc/config/podkop'),before);
    assert.ok(!JSON.stringify(r).includes('SECRET_SUBSCRIPTION'));
    assert.ok(!read(f,'/etc/podkop-failover/events.log').includes('SECRET_SUBSCRIPTION'));
  }
});
test('native UCI + Podkop parser + sing-box check dry run preserve runtime',async()=>{
  const f=fixture(),before=read(f,'/etc/config/podkop');const r=await update(f,['--dry-run']);
  assert.equal(r.ok,true,r.stderr);assert.equal(read(f,'/etc/config/podkop'),before);
  assert.ok(!fs.existsSync(f.root+'/actions'));
});
test('real VLESS/SOCKS HTTP and HTTPS preflight; commit preserves manual and unrelated sections',async()=>{
  const f=fixture(),n=requests;const r=await update(f);assert.equal(r.ok,true,r.stderr);
  assert.ok(requests>n,'real requests must arrive at local origin');
  const config=read(f,'/etc/config/podkop');assert.ok(config.includes('manual-main'));assert.ok(config.includes('zt-safe'));
  assert.ok(config.includes('new-main-rwsub'));assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'NORMAL');
});
test('syntactically valid but dead VPN credentials fail real traffic preflight without apply',async()=>{
  const f=fixture(),before=read(f,'/etc/config/podkop');write(f.root+'/body',link('main',badUuid)+'\n'+link('us-direct-reality',badUuid)+'\n');
  const r=await update(f);assert.equal(r.ok,false);assert.match(r.stderr,/HTTP probes failed/);
  assert.equal(read(f,'/etc/config/podkop'),before);assert.ok(!fs.existsSync(f.root+'/actions'));
});
test('activation failure restores previous configuration and leaves DIRECT DNS',async()=>{
  const f=fixture(),before=read(f,'/etc/config/podkop');write(f.root+'/start-fail','');
  const r=await update(f);assert.equal(r.ok,false);assert.equal(read(f,'/etc/config/podkop'),before);
  assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
  assert.ok(read(f,'/etc/config/dhcp').includes('9.9.9.9'));assert.ok(!fs.existsSync(f.root+'/etc/podkop-failover/transaction/pending'));
});
test('stopped sing-box, DNS failure and dead runtime keys require three consecutive failures',async()=>{
  for(const failure of ['process-fail','dns-fail','api-fail','api-USA-fail']){
    const f=fixture();write(f.root+'/'+failure,'');
    for(let i=0;i<2;i++)await shell(f,'guard_tick');
    assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'NORMAL');
    await shell(f,'guard_tick');assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
    const actions=read(f,'/actions');assert.ok(!/flush|table 52|zerotier|tailscale/.test(actions));
    assert.match(read(f,'/nft-input'),/198\.18\.0\.0\/15 reject/);
  }
});
test('transient failure resets counter and recovery needs three real preflights',async()=>{
  const f=fixture();write(f.root+'/process-fail','');await shell(f,'guard_tick');
  fs.unlinkSync(f.root+'/process-fail');await shell(f,'guard_tick');assert.equal(read(f,'/tmp/podkop-failover/failures').trim(),'0');
  await shell(f,'fail_open');for(let i=0;i<2;i++)await shell(f,'guard_tick');
  assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
  await shell(f,'guard_tick');assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'NORMAL');
  write(f.root+'/process-fail','');await shell(f,'guard_tick');
  assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'NORMAL','a new outage must require three fresh failures');
});
test('boot restores unfinished transaction and starts DIRECT; manual DIRECT survives update',async()=>{
  const f=fixture(),before=read(f,'/etc/config/podkop');
  await shell(f,'backup_transaction');write(f.cfg+'/podkop','corrupted');
  fs.rmSync(f.root+'/tmp/podkop-failover',{recursive:true});
  await exec(ash,[repo+'/scripts/podkop-failover-guard.sh','boot'],{env:f.env});
  assert.equal(read(f,'/etc/config/podkop'),before);assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
  write(f.root+'/etc/podkop-failover/manual-direct','');
  const r=await update(f);assert.equal(r.ok,true,r.stderr);assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
});
test('shared flock rejects parallel updater; bounded logs rotate',async()=>{
  const f=fixture();fs.mkdirSync(f.root+'/var/lock',{recursive:true});
  const hold=spawn('flock',[f.root+'/var/lock/podkop-control.lock','sleep','5']);
  await new Promise(r=>setTimeout(r,100));const r=await update(f);hold.kill();assert.equal(r.ok,false);
  write(f.root+'/etc/podkop-failover/events.log','x'.repeat(66000));await shell(f,"event 'fixed message'");
  assert.ok(fs.existsSync(f.root+'/etc/podkop-failover/events.log.1'));
  assert.ok(read(f,'/etc/podkop-failover/events.log').length<200);
});
test('invalid current USA triggers DIRECT and cannot recover; cooldown prevents restart attempts',async()=>{
  const f=fixture();await exec(runtime+'/bin/uci',['-c',f.cfg,'delete','podkop.USA.urltest_proxy_links'],{env:f.env});
  await exec(runtime+'/bin/uci',['-c',f.cfg,'commit','podkop'],{env:f.env});
  for(let i=0;i<3;i++)await shell(f,'guard_tick');
  assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
  for(let i=0;i<3;i++)await shell(f,'guard_tick');
  assert.ok(!read(f,'/actions').includes('podkop start'));
  const g=fixture();await shell(g,'fail_open');g.env.COOLDOWN='300';
  await shell(g,'guard_tick');assert.ok(!read(g,'/actions').includes('podkop start'));
});
test('unchanged subscription leaves runtime untouched; dry run never repairs pending transaction',async()=>{
  const f=fixture();assert.equal((await update(f)).ok,true);
  const actions=read(f,'/actions');const r=await update(f);assert.equal(r.ok,true,r.stderr);
  assert.equal(read(f,'/actions'),actions);
  await shell(f,'backup_transaction');const config=read(f,'/etc/config/podkop');
  const dry=await update(f,['--dry-run']);assert.equal(dry.ok,false);
  assert.equal(read(f,'/etc/config/podkop'),config);
  assert.ok(fs.existsSync(f.root+'/etc/podkop-failover/transaction/pending'));
});
test('real HTTPS subscription download verifies TLS; HTTP 503 preserves working keys',async()=>{
  for(const endpoint of ['subscription','unavailable']){
    const f=fixture(),before=read(f,'/etc/config/podkop');write(f.root+'/real-download','');
    write(f.root+'/etc/podkop-remnawave/subscription.conf',`SUB_URL='https://127.0.0.1:${network.sp}/${endpoint}'\n`);
    subscriptionBody=Buffer.from(link('native-main')+'\n'+link('us-direct-reality')+'\n').toString('base64');
    const r=await update(f);
    if(endpoint==='subscription')assert.equal(r.ok,true,r.stderr);
    else {assert.equal(r.ok,false);assert.equal(read(f,'/etc/config/podkop'),before);}
  }
});
test('valid fresh subscription repairs an already empty USA while preserving its section',async()=>{
  const f=fixture();await exec(runtime+'/bin/uci',['-c',f.cfg,'delete','podkop.USA.urltest_proxy_links'],{env:f.env});
  await exec(runtime+'/bin/uci',['-c',f.cfg,'commit','podkop'],{env:f.env});
  const r=await update(f);assert.equal(r.ok,true,r.stderr);
  assert.ok(read(f,'/etc/config/podkop').includes('us-direct-reality-rwsub'));
  assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'NORMAL');
});
test('DIRECT checks WAN without sing-box and resets recovery after DNS outage',async()=>{
  const f=fixture();await shell(f,'fail_open');write(f.root+'/wan-fail','');
  for(let i=0;i<3;i++)await shell(f,'guard_tick');
  assert.equal(read(f,'/tmp/podkop-failover/wan').trim(),'UNREACHABLE');
  assert.ok(!read(f,'/actions').includes('podkop start'));
  fs.unlinkSync(f.root+'/wan-fail');await shell(f,'guard_tick');
  assert.equal(read(f,'/tmp/podkop-failover/successes').trim(),'1');
  write(f.root+'/direct-dns-fail','');await shell(f,'guard_tick');
  assert.equal(read(f,'/tmp/podkop-failover/successes').trim(),'0');
});

test('DIRECT DNS restart failure restores disk and never stops its sing-box upstream',async()=>{
  const f=fixture(),before=read(f,'/etc/config/dhcp');write(f.root+'/restart-fail','');
  await assert.rejects(shell(f,'fail_open'));
  assert.equal(read(f,'/etc/config/dhcp'),before);
  assert.ok(!read(f,'/actions').includes('podkop stop'));
  fs.unlinkSync(f.root+'/restart-fail');await shell(f,'fail_open');
  assert.ok(read(f,'/etc/config/dhcp').includes('9.9.9.9'));
  const a=read(f,'/actions');assert.ok(a.lastIndexOf('dnsmasq restart')<a.indexOf('podkop stop'));
});
test('failure at FakeIP barrier or interception removal aborts before stopping DNS upstream',async()=>{
  for(const fault of ['block-fail','remove-fail']){
    const f=fixture();write(f.root+'/'+fault,'');await assert.rejects(shell(f,'fail_open'));
    assert.ok(!read(f,'/actions').includes('podkop stop'));
    fs.unlinkSync(f.root+'/'+fault);await shell(f,'fail_open');
    assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
  }
});
test('recovery failures after start, health, DNS restore or FakeIP unblock return to DIRECT',async()=>{
  for(const fault of ['start-fail','api-USA-fail','restart-fail','unblock-fail']){
    const f=fixture();await shell(f,'fail_open');write(f.root+'/'+fault,'');
    await shell(f,'if activate_normal; then exit 99; else fail_open || true; fi');
    assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
    assert.ok(read(f,'/etc/config/dhcp').includes('9.9.9.9'),fault);
    assert.ok(!read(f,'/etc/config/dhcp').includes('127.0.0.42'),fault);
  }
});
test('cold boot skips cooldown but still requires three real successful probes',async()=>{
  const f=fixture();f.env.COOLDOWN='300';
  await exec(ash,[repo+'/scripts/podkop-failover-guard.sh','boot'],{env:f.env});
  assert.ok(!fs.existsSync(f.root+'/tmp/podkop-failover/last-transition'));
  for(let i=0;i<2;i++)await shell(f,'guard_tick');
  assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
  await shell(f,'guard_tick');assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'NORMAL');
});

test('interrupted DNS disk/runtime transaction forces restart even when files match',async()=>{
  const f=fixture();await shell(f,'fail_open');
  write(f.root+'/etc/podkop-failover/dns-pending','');
  const before=read(f,'/actions');await shell(f,'dns_mode direct');
  assert.ok(read(f,'/actions').slice(before.length).includes('dnsmasq restart'));
  assert.ok(!fs.existsSync(f.root+'/etc/podkop-failover/dns-pending'));
});
test('partial rollback retains pending journal and retry completes restoration',async()=>{
  const f=fixture(),before=read(f,'/etc/config/podkop');await shell(f,'backup_transaction');
  write(f.cfg+'/podkop','corrupted');
  await assert.rejects(shell(f,'atomic_copy() { return 1; }; recover_transaction'));
  assert.ok(fs.existsSync(f.root+'/etc/podkop-failover/transaction/pending'));
  await shell(f,'recover_transaction');assert.equal(read(f,'/etc/config/podkop'),before);
  assert.ok(!fs.existsSync(f.root+'/etc/podkop-failover/transaction/pending'));
});
test('changed native DNS ownership prevents recovery and bypasses native stop',async()=>{
  const f=fixture();await exec(runtime+'/bin/uci',['-c',f.cfg,'set','podkop.settings.dont_touch_dhcp=0'],{env:f.env});
  await exec(runtime+'/bin/uci',['-c',f.cfg,'commit','podkop'],{env:f.env});
  await shell(f,'fail_open');await assert.rejects(shell(f,'activate_normal'));
  assert.ok(!read(f,'/actions').includes('podkop stop'));
  assert.ok(read(f,'/actions').includes('sing-box stop'));
  assert.ok(read(f,'/etc/config/dhcp').includes('9.9.9.9'));
});

test('persistent dnsmasq restart errors are rate limited after one compensation',async()=>{
  const f=fixture();f.env.COOLDOWN='300';write(f.root+'/restart-fail','');
  await assert.rejects(shell(f,'fail_open'));const actions=read(f,'/actions');
  await assert.rejects(shell(f,'fail_open'));
  assert.equal((read(f,'/actions').match(/dnsmasq restart/g)||[]).length,2);
  assert.equal((actions.match(/dnsmasq restart/g)||[]).length,2);
  assert.ok(!read(f,'/actions').includes('podkop stop'));
});
test('procd still registers watchdog after a failed boot transition',async()=>{
  const f=fixture();write(f.root+'/boot-failure','#!/bin/sh\nexit 1\n');
  const init=fs.readFileSync(repo+'/scripts/podkop-failover-guard.init','utf8').replace('/usr/bin/podkop-failover-guard boot',f.root+'/boot-failure');
  write(f.root+'/guard.init',init);
  const result=await exec(ash,['-c',`procd_open_instance() { :; }; procd_close_instance() { :; }; procd_set_param() { echo "$*"; }; . '${f.root}/guard.init'; start_service`],{env:f.env});
  assert.match(result.stdout,/command \/usr\/bin\/podkop-failover-guard daemon/);
});
test('DNS health failure after normal DNS restore compensates back to DIRECT',async()=>{
  const f=fixture();await shell(f,'fail_open');
  await shell(f,'n=0; dns_health() { n=$((n+1)); [ "$n" -lt 2 ]; }; if activate_normal; then exit 99; else fail_open; fi');
  assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
  assert.ok(read(f,'/etc/config/dhcp').includes('9.9.9.9'));
  assert.ok(!read(f,'/etc/config/dhcp').includes('127.0.0.42'));
});

test('concurrent edit between candidate copy and hash capture cannot be overwritten',async()=>{
  const f=fixture();write(f.root+'/bin/sha256sum',`#!/bin/sh
case "$1" in
 */.subscription.*/podkop) /usr/bin/sha256sum "$@"; echo '# concurrent manual edit' >> "$PODKOP_ROOT/etc/config/podkop";;
 *) exec /usr/bin/sha256sum "$@";;
esac
`);
  const r=await update(f);assert.equal(r.ok,false);assert.match(r.stderr,/changed concurrently/);
  assert.ok(read(f,'/etc/config/podkop').includes('# concurrent manual edit'));
  assert.ok(!fs.existsSync(f.root+'/actions'));
});

test('bounded runner works without timeout and terminates a stalled direct child',async()=>{
  const f=fixture();write(f.root+'/bin/timeout','#!/bin/sh\nexit 127\n');
  await shell(f,'bounded_run 1 true');
  const start=Date.now();await assert.rejects(shell(f,'bounded_run 1 sleep 20'));
  assert.ok(Date.now()-start<4000);
  await shell(f,'shadow_health "$CFG"');
});

test('DIRECT DNS traffic must succeed before its previous sing-box upstream can stop',async()=>{
  const f=fixture();write(f.root+'/direct-dns-fail','');
  await assert.rejects(shell(f,'fail_open'));
  assert.ok(!read(f,'/actions').includes('podkop stop'));
  fs.unlinkSync(f.root+'/direct-dns-fail');await shell(f,'fail_open');
  assert.equal(read(f,'/tmp/podkop-failover/mode').trim(),'FAIL_OPEN');
});
