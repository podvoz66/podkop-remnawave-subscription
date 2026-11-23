import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFile,spawn} from 'node:child_process';
import {promisify} from 'node:util';
const exec=promisify(execFile), repo=path.resolve(import.meta.dirname,'..');
const runtime=process.env.OPENWRT_RUNTIME;
if(!runtime)throw Error('OPENWRT_RUNTIME required');
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'independent-rollback-'));
after(()=>fs.rmSync(tmp,{recursive:true,force:true}));
const engine=repo+'/scripts/rollback/openwrt-rollback.sh';
const host=repo+'/scripts/rollback/proxmox-rollback.sh';
const ash=runtime+'/bin/ash';
const write=(p,s,mode=0o700)=>{fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,s,{mode});};
function fixture(){
 const root=fs.mkdtempSync(tmp+'/guest-'), bin=root+'/bin';
 write(root+'/proc/uptime','1000.00 0.00\n');
 write(root+'/proc/sys/kernel/random/boot_id','synthetic-boot-A\n');
 fs.mkdirSync(root+'/dev',{recursive:true});fs.symlinkSync('/dev/urandom',root+'/dev/urandom');
 for(const f of ['network','firewall','podkop'])write(root+'/etc/config/'+f,'baseline '+f+'\n');
 write(root+'/etc/config/sing-box',"config sing-box 'main'\n option enabled '1'\n option conffile '/etc/sing-box/config.json'\n");
 write(root+'/etc/config/dhcp',"config dnsmasq\n list server '127.0.0.42'\n option noresolv '1'\n");
 write(root+'/etc/sing-box/config.json',JSON.stringify({route:{rule_set:[{type:'local',path:'/tmp/sing-box/rulesets/main.json'}]}}));
 write(root+'/tmp/sing-box/rulesets/main.json','{}\n');
 write(root+'/etc/crontabs/root','baseline cron\n');
 for(const service of ['podkop','sing-box','dnsmasq','cron'])write(root+'/etc/init.d/'+service,`#!/bin/sh
echo '${service}' "$*" >> "$ROLLBACK_ROOT/actions"
[ ! -f "$ROLLBACK_ROOT/service-fail" ]
`);
 fs.mkdirSync(root+'/etc/rc.d');fs.symlinkSync('../init.d/podkop',root+'/etc/rc.d/S99podkop');fs.symlinkSync('../init.d/dnsmasq',root+'/etc/rc.d/S19dnsmasq');
 write(bin+'/ubus',`#!/bin/sh
echo "ubus $*" >> "$ROLLBACK_ROOT/actions"
case "$*" in
 *delete*) echo '{}';;
 *openwrt-emergency-rollback*) [ ! -f "$ROLLBACK_ROOT/watch-dead" ] || { echo '{}'; exit; }; echo '{"openwrt-emergency-rollback":{"instances":{"main":{"running":true}}}}';;
 *sing-box*) [ ! -f "$ROLLBACK_ROOT/singbox-dead" ] && echo '{"sing-box":{"instances":{"main":{"running":true}}}}' || echo '{}';;
 *) echo '{"podkop-failover-guard":{"instances":{}}}';;
esac
`);
 write(bin+'/nft',`#!/bin/sh
echo "nft $*" >> "$ROLLBACK_ROOT/actions"
case "$*" in
 '-s list table inet PodkopTable') echo 'table inet PodkopTable {}';;
 '-s list table inet fw4') echo 'table inet fw4 {}';;
 '-f -') cat >/dev/null;;
esac
`);
 write(bin+'/ip',`#!/bin/sh
echo "ip $*" >> "$ROLLBACK_ROOT/actions"
case "$*" in
 '-4 rule show') [ -f "$ROLLBACK_ROOT/removed" ] || echo '105: from all fwmark 0x100000/0x100000 lookup podkop';;
 '-4 rule del priority 105 fwmark 0x100000/0x100000 table podkop') touch "$ROLLBACK_ROOT/removed";;
 '-4 route show table podkop') echo 'local default dev lo scope host';;
esac
`);
 write(bin+'/sing-box','#!/bin/sh\n[ ! -f "$ROLLBACK_ROOT/singbox-dead" ]\n');
 // DNS, public internet, Tailscale, GitHub and the new guard are UNUSABLE.
 for(const c of ['curl','nslookup','tailscale','podkop-failover-guard','ssh'])write(bin+'/'+c,'#!/bin/sh\necho forbidden-network-or-guard >> "$ROLLBACK_ROOT/forbidden"\nexit 127\n');
 const env={...process.env,ROLLBACK_ROOT:root,PATH:bin+':'+runtime+'/bin:'+process.env.PATH};
 return {root,env,base:root+'/etc/podkop-emergency/case1'};
}
const run=(f,...args)=>exec(ash,[engine,...args],{env:f.env,timeout:20000});
async function capture(f){await run(f,'capture','case1');const hash=fs.readFileSync(f.base+'/bundle.sha256','utf8').split(' ')[0];await run(f,'accept','case1',hash);return hash;}
const state=f=>fs.readFileSync(f.base+'/state','utf8').trim();
function damage(f){
 write(f.root+'/etc/config/dhcp','BROKEN DNS\n');write(f.root+'/etc/config/podkop','BROKEN PODKOP\n');
 write(f.root+'/etc/crontabs/root','BROKEN CRON\n');fs.unlinkSync(f.root+'/tmp/sing-box/rulesets/main.json');
 write(f.root+'/usr/bin/podkop-failover-guard','#!/bin/sh\nexit 127\n');
 write(f.root+'/usr/lib/podkop-failover.sh','BROKEN GUARD LIB');
 fs.unlinkSync(f.root+'/etc/rc.d/S99podkop');fs.symlinkSync('../init.d/podkop-failover-guard',f.root+'/etc/rc.d/S95podkop-failover-guard');
}
test('guest deadline restores local files/runtime plan without internet/DNS/Tailscale/guard',async()=>{
 const f=fixture();await capture(f);await run(f,'arm','case1','60');damage(f);
 write(f.root+'/proc/uptime','1061.00 0.00\n');await run(f,'check','case1');
 assert.equal(state(f),'RESTORED_UNVERIFIED');
 assert.match(fs.readFileSync(f.root+'/etc/config/podkop','utf8'),/baseline/);
 assert.match(fs.readFileSync(f.root+'/etc/config/dhcp','utf8'),/127.0.0.42/);
 assert.equal(fs.readFileSync(f.root+'/etc/crontabs/root','utf8'),'baseline cron\n');
 assert.ok(fs.existsSync(f.root+'/tmp/sing-box/rulesets/main.json'));
 assert.ok(!fs.existsSync(f.root+'/usr/bin/podkop-failover-guard'));
 assert.equal(fs.readlinkSync(f.root+'/etc/rc.d/S99podkop'),'../init.d/podkop');
 assert.ok(!fs.existsSync(f.root+'/forbidden'));
 const actions=fs.readFileSync(f.root+'/actions','utf8');
 assert.ok(!/flush|restart network|restart firewall|tailscale|zerotier/.test(actions));
 assert.match(actions,/ubus call service delete/);
 const before=actions;await run(f,'restore','case1');assert.equal(fs.readFileSync(f.root+'/actions','utf8'),before,'duplicate host rollback must not restart services again');
});
test('expired guest canary fires with SSH unusable; no network/service mutation',async()=>{
 const f=fixture();await run(f,'arm-canary','case1','60');
 write(f.root+'/proc/uptime','1061.00 0.00\n');await run(f,'check','case1');
 assert.equal(state(f),'CANARY_FIRED');assert.ok(!/nft|ip |sing-box|dnsmasq/.test(fs.readFileSync(f.root+'/actions','utf8')));assert.ok(!fs.existsSync(f.root+'/forbidden'));
});
test('guest monotonic deadline ignores wall clock; boot change fails safe immediately',async()=>{
 const f=fixture();await capture(f);await run(f,'arm','case1','60');await run(f,'check','case1');assert.equal(state(f),'ARMED');
 write(f.root+'/proc/sys/kernel/random/boot_id','synthetic-boot-B\n');write(f.root+'/proc/uptime','3.00 0.00\n');await run(f,'check','case1');assert.equal(state(f),'RESTORED_UNVERIFIED');
});
test('confirmation requires token and unexpired deadline; health is never auto-attested',async()=>{
 const f=fixture();await capture(f);await run(f,'arm','case1','60');
 await assert.rejects(run(f,'confirm','case1','wrong'));assert.equal(state(f),'ARMED');
 const token=fs.readFileSync(f.base+'/token','utf8');await run(f,'confirm','case1',token);await run(f,'check','case1');assert.equal(state(f),'CONFIRMED');
 const g=fixture();await capture(g);await run(g,'arm','case1','60');write(g.root+'/proc/uptime','1061.00 0.00\n');await assert.rejects(run(g,'confirm','case1',fs.readFileSync(g.base+'/token','utf8')));
});
test('corrupt archive, changed network/firewall and occupied control lock block unsafe restore',async()=>{
 for(const fault of ['archive','network','firewall','lock']){
  const f=fixture();await capture(f);damage(f);
  let hold;
  if(fault==='archive')fs.appendFileSync(f.base+'/bundle.tar','corrupt');
  if(fault==='network')write(f.root+'/etc/config/network','unrelated change');
  if(fault==='firewall')write(f.root+'/etc/config/firewall','unrelated change');
  if(fault==='lock'){fs.mkdirSync(f.root+'/var/lock',{recursive:true});hold=spawn('flock',[f.root+'/var/lock/podkop-control.lock','sleep','10']);await new Promise(r=>setTimeout(r,100));}
  try{await assert.rejects(run(f,'restore','case1'));assert.equal(fs.readFileSync(f.root+'/etc/config/podkop','utf8'),'BROKEN PODKOP\n');}
  finally{if(hold)hold.kill();}
 }
});
test('dead baseline sing-box uses separate DIRECT DNS, never calls new guard',async()=>{
 const f=fixture();await capture(f);damage(f);write(f.root+'/singbox-dead','');await run(f,'restore','case1');
 assert.equal(state(f),'DIRECT_UNVERIFIED');assert.match(fs.readFileSync(f.root+'/etc/config/dhcp','utf8'),/9.9.9.9/);
 assert.ok(!fs.existsSync(f.root+'/forbidden'));
});
test('rollback failure remains armed, retries are bounded and service errors are not success',async()=>{
 const f=fixture();await capture(f);await run(f,'arm','case1','60');write(f.root+'/service-fail','');
 for(let n=1;n<=3;n++){write(f.root+'/proc/uptime',`${1000+n*61}.00 0.00\n`);await assert.rejects(run(f,'check','case1'));assert.equal(state(f),'ARMED');}
 write(f.root+'/proc/uptime','1300.00 0.00\n');await assert.rejects(run(f,'check','case1'));assert.equal(state(f),'BLOCKED');
});
test('host copy imports over a damaged/missing guest backup without guard dependency',async()=>{
 const f=fixture();const hash=await capture(f), bundle=fs.readFileSync(f.base+'/bundle.tar');damage(f);
 fs.rmSync(f.base+'/snapshot',{recursive:true});
 const child=spawn(ash,[engine,'import','case1',hash],{env:f.env,stdio:['pipe','pipe','pipe']});
 child.stdin.end(bundle);let errors='';child.stderr.on('data',c=>errors+=c);
 assert.equal(await new Promise(r=>child.once('exit',r)),0,errors);await run(f,'restore','case1');assert.equal(state(f),'RESTORED_UNVERIFIED');
});
test('host timer canary needs no SSH/network and survives client-process exit',async()=>{
 const f=fixture(), root=f.root+'/host', env={...f.env,PROXMOX_ROLLBACK_ROOT:root};
 await exec('bash',[host,'arm-canary','case1','60'],{env});
 // The arming process has exited. Force its saved monotonic deadline into the past.
 write(root+'/case1/deadline','0\n');await exec('bash',[host,'check','case1'],{env});
 assert.equal(fs.readFileSync(root+'/case1/state','utf8').trim(),'CANARY_FIRED');assert.ok(!fs.existsSync(f.root+'/forbidden'));
});
test('host SSH failure stays ARMED and is reported as BLOCKER; no false recovery',async()=>{
 const f=fixture(), root=f.root+'/host', d=root+'/case1', env={...f.env,PROXMOX_ROLLBACK_ROOT:root};
 fs.mkdirSync(d,{recursive:true});write(d+'/bundle.tar','fixture');write(d+'/restore.sh','fixture');
 await exec('bash',['-c','sha256sum bundle.tar restore.sh > pinned.sha256'],{cwd:d});
 write(d+'/state','ARMED\n');write(d+'/boot',fs.readFileSync('/proc/sys/kernel/random/boot_id'));write(d+'/deadline','0\n');write(d+'/attempts','0\n');
 await assert.rejects(exec('bash',[host,'check','case1'],{env}),e=>/BLOCKER/.test(e.stderr));
 assert.equal(fs.readFileSync(d+'/state','utf8').trim(),'ARMED');
 assert.ok(fs.existsSync(f.root+'/forbidden'));
});
test('host protocol repairs missing guest engine and backup using its own pinned copies',async()=>{
 const f=fixture();await capture(f);const root=f.root+'/host',d=root+'/case1';fs.mkdirSync(d,{recursive:true});
 fs.copyFileSync(f.base+'/bundle.tar',d+'/bundle.tar');fs.copyFileSync(engine,d+'/restore.sh');
 await exec('bash',['-c','sha256sum bundle.tar restore.sh > pinned.sha256'],{cwd:d});
 write(d+'/state','ARMED\n');write(d+'/boot',fs.readFileSync('/proc/sys/kernel/random/boot_id'));write(d+'/deadline','0\n');write(d+'/attempts','0\n');
 damage(f);fs.rmSync(f.base+'/snapshot',{recursive:true});
 write(f.root+'/bin/ssh',`#!${process.execPath}
const fs=require('fs'),{spawnSync}=require('child_process');
const cmd=process.argv.at(-1),root=process.env.ROLLBACK_ROOT;
if(cmd==='umask 077; mkdir -p /etc/podkop-emergency; cat > /etc/podkop-emergency/host-restore-case1.sh'){
 fs.writeFileSync(root+'/etc/podkop-emergency/host-restore-case1.sh',fs.readFileSync(0));process.exit(0);
}
const m=cmd.match(/^\\/bin\\/sh \\/etc\\/podkop-emergency\\/host-restore-case1.sh (import|restore|status) case1(?: ([0-9a-f]{64}))?$/);
if(!m)process.exit(64);
const args=[root+'/etc/podkop-emergency/host-restore-case1.sh',m[1],'case1'];if(m[2])args.push(m[2]);
const out=spawnSync('${ash}',args,{env:process.env,stdio:'inherit'});process.exit(out.status??1);
`);
 await exec('bash',[host,'check','case1'],{env:{...f.env,PROXMOX_ROLLBACK_ROOT:root},timeout:20000});
 assert.equal(fs.readFileSync(d+'/state','utf8').trim(),'RESTORED_UNVERIFIED');
 assert.match(fs.readFileSync(f.root+'/etc/config/podkop','utf8'),/baseline/);
 assert.ok(!fs.existsSync(f.root+'/forbidden'));
});

test('arming refuses a missing local rollback supervisor',async()=>{
 const f=fixture();await capture(f);write(f.root+'/watch-dead','');
 await assert.rejects(run(f,'arm','case1','60'));assert.equal(state(f),'CAPTURED');
});
test('systemd units parse against a disposable fixture root without installing services',async()=>{
 const r=tmp+'/systemd-root';fs.mkdirSync(r+'/etc/systemd/system',{recursive:true});
 for(const name of ['proxmox-rollback.service','proxmox-rollback.timer']){
  fs.copyFileSync(repo+'/scripts/rollback/'+name,r+'/etc/systemd/system/'+name);fs.chmodSync(r+'/etc/systemd/system/'+name,0o644);
 }
 write(r+'/usr/local/libexec/proxmox-rollback-watch','#!/bin/sh\nexit 0\n',0o755);
 for(const name of ['sysinit.target','basic.target','timers.target','shutdown.target'])write(r+'/etc/systemd/system/'+name,'[Unit]\nDescription=Fixture target\n',0o644);
 await exec('systemd-analyze',['verify','--man=no','--root='+r,'proxmox-rollback.service','proxmox-rollback.timer']);
});

test('canary or second capture cannot overwrite/disarm a pending real rollback',async()=>{
 const f=fixture();await capture(f);await run(f,'arm','case1','60');
 const before=fs.readFileSync(f.base+'/deadline','utf8');
 await assert.rejects(run(f,'arm-canary','case1','60'));
 await assert.rejects(run(f,'capture','case2'));
 assert.equal(state(f),'ARMED');assert.equal(fs.readFileSync(f.base+'/deadline','utf8'),before);
 assert.ok(!fs.existsSync(f.base+'/canary'));assert.ok(!fs.existsSync(f.root+'/etc/podkop-emergency/case2'));
});

test('capture refuses a native init pointing at a different config',async()=>{
 const f=fixture();write(f.root+'/etc/config/sing-box',"config sing-box 'main'\n option enabled '1'\n option conffile '/other/config.json'\n");
 await assert.rejects(run(f,'capture','case1'));assert.ok(!fs.existsSync(f.base+'/state'));
});
