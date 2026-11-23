#!/usr/bin/env node
// Resumable upload ONLY to LAB204 through the installed restricted serial wrapper.
import {spawn} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const [file]=process.argv.slice(2);
if(!file || process.argv.length!==3) throw Error('usage: r12-serial-bulk.mjs FILE');
const data=readFileSync(file), hash=createHash('sha256').update(data).digest('hex');
if(!data.length || data.length>64*1024*1024) throw Error('size must be 1 byte..64 MiB');
const receiver=`import os,sys,termios,tty,select,time,hashlib,stat
f='/tmp/r12-bulk-${hash}'
fd=sys.stdin.fileno(); old=termios.tcgetattr(fd); end=time.monotonic()+85
def say(s):
 os.write(1,(s+'\\n').encode())
def get(n):
 b=b''
 while len(b)<n:
  if time.monotonic()>end or not select.select([fd],[],[],5)[0]: raise TimeoutError()
  v=os.read(fd,n-len(b))
  if not v: raise EOFError()
  b+=v
 return b
try:
 tty.setraw(fd)
 fast=termios.tcgetattr(fd); fast[4]=termios.B4000000; fast[5]=termios.B4000000
 termios.tcsetattr(fd,termios.TCSANOW,fast)
 if os.path.lexists(f):
  s=os.lstat(f)
  if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or s.st_size>${data.length}: raise ValueError('unsafe resume file')
 with os.fdopen(os.open(f,os.O_WRONLY|os.O_APPEND|os.O_CREAT|os.O_NOFOLLOW,0o600),'ab',buffering=0) as out:
  os.chmod(f,0o600); offset=out.tell(); say('R12BULK_READY '+str(offset))
  while offset<${data.length}:
   n=int.from_bytes(get(4),'big')
   if n==0: break
   if n>32768 or offset+n>${data.length}: raise ValueError('frame length')
   b=get(n); out.write(b); offset+=n; say('R12BULK_ACK '+str(offset))
 if offset==${data.length}:
  with open(f,'rb') as src: actual=hashlib.file_digest(src,'sha256').hexdigest()
  say('R12BULK_SHA '+actual)
 else: say('R12BULK_PAUSED '+str(offset))
except Exception as e: say('R12BULK_ERROR '+type(e).__name__)
finally: termios.tcsetattr(fd,termios.TCSANOW,old)
`;
const shell="python3 -u -c \"$(printf '%s' '"+Buffer.from(receiver).toString('base64')+"' | base64 -d)\"";
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let offset=0;
for(let session=0;session<40 && offset<data.length;session++){
 const child=spawn('ssh',['-T','-o','BatchMode=yes','-o','ConnectTimeout=8','proxmox-cloud','sudo','-n','/usr/local/sbin/codexops-r12-lab','serial','204']);
 let output='',closed=false;
 child.stdout.on('data',b=>output+=b.toString().replaceAll('\r',''));
 child.stderr.on('data',b=>output+=b.toString());
 child.on('close',()=>closed=true); child.stdin.on('error',()=>{});
 async function wait(re){const end=Date.now()+12000;while(Date.now()<end){const m=output.match(re);if(m)return m;if(closed)break;await sleep(10);}throw Error('serial timeout: '+output.slice(-400));}
 try {
  child.stdin.write('\n'); await sleep(300);
  child.stdin.write("printf '\\nR12BULK_ROOT_%s\\n' \"$(id -u)\"\n");
  await wait(/\nR12BULK_ROOT_0\n/);
  // Keep shell command below canonical tty line length.
  if(Buffer.byteLength(shell)>3900)throw Error('receiver command too long');
  child.stdin.write(shell+'\n');
  offset=Number((await wait(/R12BULK_READY (\d+)\n/))[1]);
  if(offset>data.length)throw Error('remote offset exceeds source');
  const end=Date.now()+70000;
  while(offset<data.length && Date.now()<end){
   const chunk=data.subarray(offset,offset+32768), header=Buffer.alloc(4);header.writeUInt32BE(chunk.length);
   child.stdin.write(Buffer.concat([header,chunk])); offset+=chunk.length;
   await wait(new RegExp('\\nR12BULK_ACK '+offset+'\\n'));
  }
  if(offset===data.length){
   const actual=(await wait(/\nR12BULK_SHA ([a-f0-9]{64})\n/))[1];
   if(actual!==hash)throw Error('SHA256 mismatch');
   console.log(JSON.stringify({path:'/tmp/r12-bulk-'+hash,bytes:data.length,sha256:hash,verified:true}));
  }else{child.stdin.write(Buffer.alloc(4));await wait(/\nR12BULK_PAUSED \d+\n/);console.error('checkpoint '+offset+'/'+data.length);}
  await sleep(200);
 }finally{child.stdin.end(); await sleep(500);}
}
if(offset!==data.length)throw Error('session limit; remote partial retained for resume');
