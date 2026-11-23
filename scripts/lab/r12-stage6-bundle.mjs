#!/usr/bin/env node
// Emits a Debian LAB204 prepare script; does not connect or execute anything.
import {readFileSync} from 'node:fs';
const encode=name=>readFileSync(new URL(name,import.meta.url)).toString('base64').match(/.{1,76}/g).join('\n');
let script=readFileSync(new URL('r12-stage6-prepare.sh.in',import.meta.url),'utf8');
script=script.replace('@FIXTURE_BASE64@',()=>encode('r12-stage6-fixture.py')).replace('@CONTROL_BASE64@',()=>encode('r12-stage6-control.sh'));
process.stdout.write(script);
