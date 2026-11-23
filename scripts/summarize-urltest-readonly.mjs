#!/usr/bin/env node
// Only accepts the already redacted JSONL observer format; no router operations.
import fs from 'node:fs';
const rows=fs.readFileSync(process.argv[2],'utf8').trim().split('\n').map(JSON.parse);
const start=rows[0].time,end=rows.at(-1).time,nodes={},events=new Set(),changes=[],previous={};
for(const row of rows)for(const item of row.rows||[]){
 if(item.kind==='events'){for(const event of item.lines)events.add(event);continue;}
 if(item.kind!=='api')continue;
 for(const node of item.nodes){
  const out=nodes[node.tag]??={type:node.type,history:[],selected:[]};
  if(node.last&&!out.history.some(h=>h.time===node.last.time&&h.delay===node.last.delay))out.history.push(node.last);
  if(node.now){
   if(!out.selected.includes(node.now))out.selected.push(node.now);
   if(previous[node.tag]&&previous[node.tag]!==node.now)changes.push({time:row.time,tag:node.tag,from:previous[node.tag],to:node.now});
   previous[node.tag]=node.now;
  }
 }
}
for(const node of Object.values(nodes)){
 node.fresh=node.history.filter(h=>Date.parse(h.time)>=Date.parse(start));
 node.observation=node.fresh.length?'FRESH_DELAY_OBSERVED':node.history.length?'STALE_HISTORY_ONLY':'NO_SUCCESS_HISTORY';
}
console.log(JSON.stringify({start,end,samples:rows.length,complete:rows.filter(r=>r.complete).length,duration_seconds:(Date.parse(end)-Date.parse(start))/1000,nodes,selector_changes:changes,events:[...events],limitations:['tail250 sampling can miss events; identical lines deduplicated; events can predate window','delay history is not proof of a successful 64KiB data transfer','15-second timeout duration is not retained by this redactor; context-deadline classification only','current availability and long-term stability are separate; pinned USA can retain stale history'],download_transfer_success:'UNOBSERVED'},null,2));
