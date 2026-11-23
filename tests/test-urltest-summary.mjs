import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
test('stale successes are not current health and selector changes retain timestamps',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'r12-observer-'));
 try{
  const rows=[0,1].map(n=>({time:`2026-11-23T21:0${n}:00Z`,complete:true,rows:[{kind:'api',nodes:[{tag:'USA-1-out',type:'VLESS',last:{time:'2026-11-23T20:00:00Z',delay:100}},{tag:'main-1-out',type:'VLESS',last:{time:`2026-11-23T21:0${n}:00Z`,delay:120}},{tag:'main-urltest-out',type:'URLTest',now:n?'main-2-out':'main-1-out',last:null}]}]}));
  fs.writeFileSync(dir+'/input',rows.map(JSON.stringify).join('\n'));
  const out=JSON.parse(execFileSync(process.execPath,[path.resolve(import.meta.dirname,'../scripts/summarize-urltest-readonly.mjs'),dir+'/input'],{encoding:'utf8'}));
  assert.equal(out.nodes['USA-1-out'].observation,'STALE_HISTORY_ONLY');
  assert.equal(out.nodes['main-1-out'].fresh.length,2);
  assert.equal(out.selector_changes.length,1);
  assert.equal(out.download_transfer_success,'UNOBSERVED');
 }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
