#!/usr/bin/env node
// Guest-only script transport through the already installed restricted SSH wrapper.
// Never accesses PVE serial sockets directly; no passwords; requires existing root shell.
import {spawn} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {gzipSync} from 'node:zlib';
import {randomBytes,createHash} from 'node:crypto';
const [vm,path]=process.argv.slice(2);
if(!['203','204'].includes(vm)||!path||process.argv.length!==4)throw Error('usage: VM203|204 script.sh');
const data=readFileSync(path),nonce=randomBytes(8).toString('hex');
const hash=createHash('sha256').update(data).digest('hex');
const name='/tmp/r12-command-'+nonce;
const child=spawn('ssh',['-T','-o','BatchMode=yes','-o','ConnectTimeout=8','proxmox-cloud','sudo','-n','/usr/local/sbin/codexops-r12-lab','serial',vm],{stdio:['pipe','pipe','pipe']});
let output='',closed=false;
child.stdout.on('data',b=>{output+=b.toString().replaceAll('\r','');if(output.length>524288)output=output.slice(-262144);});
child.stderr.on('data',b=>{output+=b.toString();});
child.on('close',()=>{closed=true;});
child.stdin.on('error',()=>{});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function wait(re,ms=10000){const until=Date.now()+ms;while(Date.now()<until){const m=output.match(re);if(m)return m;if(closed)throw Error('serial closed: '+output.slice(-700));await sleep(50);}throw Error('serial response timeout: '+output.slice(-700));}
async function send(s){child.stdin.write(s+'\n');await sleep(60);}
try{
 await send('');
 await send(`printf '\\nR12READY_${nonce}_%s\\n' "$(id -u)"`);
 await wait(new RegExp(`(?:^|\\n)R12READY_${nonce}_0\\n`));
 const packed=gzipSync(data);
 if(vm==='203'){
  // Stock LAB203 BusyBox has gzip but no base64: bounded octal printf chunks.
  await send(`umask 077; : > ${name}.gz`);
  for(let i=0;i<packed.length;i+=40){
   const octal=Array.from(packed.subarray(i,i+40),n=>'\\'+n.toString(8).padStart(3,'0')).join('');
   await send(`printf '%b' '${octal}' >> ${name}.gz`);
  }
 }else{
  await send(`umask 077; cat > ${name}.b64 <<'R12DATA_${nonce}'`);
  const b64=packed.toString('base64');
  for(let i=0;i<b64.length;i+=76)await send(b64.slice(i,i+76));
  await send('R12DATA_'+nonce);
  await send(`base64 -d ${name}.b64 > ${name}.gz`);
 }
 await send(`gzip -dc ${name}.gz > ${name}.sh && printf '%s  %s\\n' ${hash} ${name}.sh | sha256sum -c - >/dev/null && { printf '\\nR12BEGIN_${nonce}\\n'; sh ${name}.sh; }; r12_rc=$?; printf '\\nR12DONE_${nonce}_%s\\n' "$r12_rc"; rm -f ${name}.b64 ${name}.gz ${name}.sh`);
 const end=await wait(new RegExp(`(?:^|\\n)R12DONE_${nonce}_([0-9]+)\\n`),80000);
 const begin=output.lastIndexOf('\nR12BEGIN_'+nonce+'\n');
 if(begin<0)throw Error('missing execution marker');
 console.log(output.slice(begin+nonce.length+11,output.lastIndexOf('\nR12DONE_'+nonce)).trim());
 console.log('R12_GUEST_RC='+end[1]);
 process.exitCode=Number(end[1])===0?0:1;
}catch(e){console.error('STOP: '+e.message);process.exitCode=1;}
finally{child.stdin.end();}
