#!/usr/bin/env node
// Codespaces-side observer: no VM files, selector changes, delay probes or service actions.
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const exec=promisify(execFile);
const [alias='openwrt-202',countText='50',intervalText='30']=process.argv.slice(2);
const count=Number(countText),interval=Number(intervalText);
if(alias!=='openwrt-202'||!Number.isInteger(count)||count<1||count>60||!Number.isInteger(interval)||interval<10||interval>60)throw Error('bounded openwrt-202 observer only');
const remote=`secret=$(jq -r '.experimental.clash_api.secret // empty' /etc/sing-box/config.json)
if [ -n "$secret" ]; then printf 'header = "Authorization: Bearer %s"\\n' "$secret"; fi | curl -fsS --max-time 3 --config - http://192.168.0.1:9090/proxies | jq -Mc '{kind:"api",nodes:[.proxies|to_entries[]|select(.key|startswith("main") or startswith("USA"))|{tag:.key,type:.value.type,now:.value.now,last:(.value.history[-1]//null)}]}'
unset secret
logread -l 250 | awk '
/context deadline exceeded/ {s=$0;sub(/^.*outbound\\/(vless|hysteria2)\\[/,"",s);sub(/\\].*$/,"",s);if(s!~/^(main|USA)-[0-9]+-out$/)s="UNKNOWN"; print $1,$2,$3,$4,$5,"TIMEOUT",s;next}
/download test/ {s=$0;sub(/^.*outbound\\/urltest\\[/,"",s);sub(/\\].*$/,"",s);if(s!~/^(main|USA)-[a-z0-9-]+$/)s="UNKNOWN";print $1,$2,$3,$4,$5,"DOWNLOAD_EVENT",s;next}
/switched from outbound/ {s=$0;sub(/^.*switched from outbound /,"",s);if(s~/^[a-zA-Z0-9-]+ to (fallback )?[a-zA-Z0-9-]+$/)print $1,$2,$3,$4,$5,"SWITCH",s}
' | jq -Rsc '{kind:"events",lines:(split("\\n")|map(select(length>0)))}'
`;
for(let n=0;n<count;n++){
 const started=Date.now();
 try{
  const {stdout}=await exec('ssh',['-T','-o','BatchMode=yes','-o','ConnectTimeout=5',alias,remote],{timeout:12000,maxBuffer:262144});
  const rows=stdout.trim().split('\n').filter(Boolean).map(x=>JSON.parse(x));
  console.log(JSON.stringify({sample:n,time:new Date().toISOString(),complete:rows.some(x=>x.kind==='api'),rows}));
 }catch(e){console.log(JSON.stringify({sample:n,time:new Date().toISOString(),complete:false,error:e.code||'OBSERVER_FAILURE'}));}
 if(n+1<count)await new Promise(r=>setTimeout(r,Math.max(0,interval*1000-(Date.now()-started))));
}
