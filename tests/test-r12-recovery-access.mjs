import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const root=new URL('../scripts/lab/',import.meta.url),file=new URL('codexops-r12-recovery',root).pathname;
for(const args of [['restore','202'],['capture','201'],['restore','204'],['restore','203;id'],['set','203'],['restore','203','extra']]){
 test('deny '+JSON.stringify(args),()=>{let r=spawnSync('bash',[file,...args],{encoding:'utf8'});assert.equal(r.status,1);assert.match(r.stderr,/only VM203|action denied/);assert.doesNotMatch(r.stderr,/PVE root required/);});
}
test('bootstrap checksum and syntax',()=>{
 const installer=new URL('install-r12-recovery.sh',root).pathname;
 const hash=createHash('sha256').update(readFileSync(file)).digest('hex');
 assert.ok(readFileSync(installer,'utf8').includes('HASH='+hash));
 for(const path of [file,installer])assert.equal(spawnSync('bash',['-n',path]).status,0);
});
test('all byte values survive serial octal encoding',()=>{
 const data=Buffer.from(Array.from({length:256},(_,i)=>i));
 const octal=Array.from(data,n=>'\\'+n.toString(8).padStart(3,'0')).join('');
 const r=spawnSync('bash',['-c',`printf '%b' '${octal}'`]);assert.equal(r.status,0);assert.deepEqual(r.stdout,data);
});
