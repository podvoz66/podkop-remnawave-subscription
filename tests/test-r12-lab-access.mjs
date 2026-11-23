import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const wrapper=new URL('../scripts/lab/codexops-r12-lab',import.meta.url).pathname;
const install=new URL('../scripts/lab/install-r12-lab-access.sh',import.meta.url).pathname;
// All negative requests must be rejected before hostname/root checks or host calls.
for(const args of [['inspect','201'],['serial','202'],['stop','202'],['start','107'],['serial','203;id'],['shell','203'],['set','204'],['serial','204','extra'],[]]) {
  test(`deny ${JSON.stringify(args)}`,()=>{
    const r=spawnSync('bash',[wrapper,...args],{encoding:'utf8'});
    assert.equal(r.status,1);
    assert.match(r.stderr,/usage:|LAB VMID only|action not allowed/);
    assert.doesNotMatch(r.stderr,/Proxmox root required/);
  });
}
test('bootstrap pins exact wrapper bytes',()=>{
  const hash=createHash('sha256').update(readFileSync(wrapper)).digest('hex');
  assert.ok(readFileSync(install,'utf8').includes(`HASH=${hash}`));
});
test('shell syntax',()=>{
  for(const p of [wrapper,install]) assert.equal(spawnSync('bash',['-n',p]).status,0);
});
