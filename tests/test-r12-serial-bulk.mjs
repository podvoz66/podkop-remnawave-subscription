// Protocol regression only: mock SSH, never a substitute for real guest SHA verification.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {randomBytes,createHash} from 'node:crypto';
const cli=path.resolve(import.meta.dirname,'../scripts/lab/r12-serial-bulk.mjs');
const mock=`#!/usr/bin/env node
const fs=require('fs'),crypto=require('crypto');
let input=Buffer.alloc(0),raw=false,size=0,file='',hash='',offset=0;
function say(s){process.stdout.write(s+'\\n')}
process.stdin.on('data',chunk=>{input=Buffer.concat([input,chunk]);
 while(true){if(!raw){let end=input.indexOf(10);if(end<0)return;let line=input.subarray(0,end).toString();input=input.subarray(end+1);
 if(line.includes('R12BULK_ROOT_'))say('\\nR12BULK_ROOT_0');
 if(line.startsWith('python3')){let encoded=line.match(/printf '%s' '([^']+)'/)[1],py=Buffer.from(encoded,'base64').toString();
 hash=py.match(/r12-bulk-([a-f0-9]{64})/)[1];size=Number(py.match(/while offset<(\\d+):/)[1]);file=process.env.MOCK_STATE+'/'+hash;
 if(!fs.existsSync(file))fs.writeFileSync(file,Buffer.alloc(Number(process.env.MOCK_PREFIX||0)));
 offset=fs.statSync(file).size;raw=true;say('R12BULK_READY '+offset);
 if(offset===size)say('R12BULK_SHA '+crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'));
 }continue;}
 if(input.length<4)return;let n=input.readUInt32BE();if(input.length<4+n)return;
 if(n===0){input=input.subarray(4);say('R12BULK_PAUSED '+offset);raw=false;continue;}
 if(n>32768)process.exit(2);fs.appendFileSync(file,input.subarray(4,4+n));input=input.subarray(4+n);offset+=n;say('R12BULK_ACK '+offset);
 if(offset===size){say('R12BULK_SHA '+(process.env.MOCK_BAD_HASH?'0'.repeat(64):crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')));raw=false;}
 }
});`;
function fixture(fn){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'r12-bulk-test-'));try{fs.writeFileSync(dir+'/ssh',mock,{mode:0o700});fn(dir);}finally{fs.rmSync(dir,{recursive:true,force:true});}}
test('bounded binary frames and resume from existing prefix verify exact SHA',()=>fixture(dir=>{
 const data=randomBytes(98317),hash=createHash('sha256').update(data).digest('hex');
 fs.writeFileSync(dir+'/source',data);fs.writeFileSync(dir+'/'+hash,data.subarray(0,117));
 const r=spawnSync(process.execPath,[cli,dir+'/source'],{env:{...process.env,PATH:dir+':'+process.env.PATH,MOCK_STATE:dir},encoding:'utf8',timeout:15000});
 assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/"verified":true/);assert.deepEqual(fs.readFileSync(dir+'/'+hash),data);
}));
test('wrong guest digest is rejected',()=>fixture(dir=>{
 fs.writeFileSync(dir+'/source',randomBytes(777));
 const r=spawnSync(process.execPath,[cli,dir+'/source'],{env:{...process.env,PATH:dir+':'+process.env.PATH,MOCK_STATE:dir,MOCK_BAD_HASH:'1'},encoding:'utf8',timeout:15000});
 assert.notEqual(r.status,0);assert.match(r.stderr,/SHA256 mismatch/);assert.doesNotMatch(r.stdout,/"verified":true/);
}));
