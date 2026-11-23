#!/usr/bin/python3
"""Temporary unprivileged PVE one-shot LAB203 serial recovery timer. Not a host service.
No VM202, qm, root sockets, guest SSH, external network, DNS or arbitrary commands.
Not reboot-persistent and not recovery from a hung guest kernel/procd.
"""
import argparse,fcntl,json,os,pathlib,re,select,subprocess,sys,time,uuid
STATE=pathlib.Path('/home/codexops/r12-native-timer')
HELPER='/root/r12-native-test/timer-restore.sh'
WRAPPER='/usr/local/sbin/codexops-r12-lab'
def save(data):
    temp=STATE/'state.new';temp.write_text(json.dumps(data));os.chmod(temp,0o600);os.replace(temp,STATE/'state.json')
def serial(action,digest):
    token='R12TIMER_'+uuid.uuid4().hex
    p=subprocess.Popen(['sudo','-n',WRAPPER,'serial','203'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    output=b'';deadline=time.monotonic()+65
    try:
        p.stdin.write(b'\n');p.stdin.flush();time.sleep(.3)
        command=f"printf '%s  %s\\n' {digest} {HELPER} | sha256sum -c - >/dev/null && sh {HELPER} {action}; r=$?; printf '\\n{token}_%s\\n' \"$r\"\n"
        p.stdin.write(command.encode());p.stdin.flush()
        while time.monotonic()<deadline:
            if not select.select([p.stdout],[],[],1)[0]:continue
            data=os.read(p.stdout.fileno(),8192)
            if not data:break
            output=(output+data)[-65536:]
            found=re.search(rb'\r?\n'+token.encode()+rb'_([0-9]+)\r?\n',output)
            if found:return int(found[1])
        raise TimeoutError('serial203 marker unavailable; no process killed outside own wrapper client')
    finally:
        p.stdin.close()
        try:p.wait(timeout=3)
        except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=3)
def main():
    os.umask(0o077)
    if os.geteuid()==0 or os.environ.get('USER')!='codexops':raise RuntimeError('codexops nonroot only')
    STATE.mkdir(mode=0o700,exist_ok=True)
    if STATE.is_symlink() or STATE.stat().st_uid!=os.geteuid() or STATE.stat().st_mode&0o077:raise RuntimeError('private state required')
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['arm','run','status','cancel']);parser.add_argument('--seconds',type=int,default=20);parser.add_argument('--operation',choices=['probe','restore'],default='probe');parser.add_argument('--sha256',default='')
    a=parser.parse_args()
    with (STATE/'lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        s=json.loads((STATE/'state.json').read_text()) if (STATE/'state.json').exists() else {}
        if a.action=='status':print(json.dumps(s));return
        if a.action=='cancel':
            if s.get('phase')!='ARMED':raise RuntimeError('only ARMED may cancel')
            s['phase']='CANCELLED';save(s);print('TIMER_CANCELLED');return
        if a.action=='arm':
            if s.get('phase') in ('ARMED','RUNNING'):raise RuntimeError('timer active')
            if not 20<=a.seconds<=120 or not re.fullmatch('[a-f0-9]{64}',a.sha256):raise RuntimeError('fixed bound/hash required')
            s={'phase':'ARMED','boot':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(),'deadline':time.monotonic()+a.seconds,'operation':a.operation,'sha256':a.sha256}
            save(s)
            with (STATE/'runner.log').open('ab') as log:
                subprocess.Popen([sys.executable,str(pathlib.Path(__file__).resolve()),'run'],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True,close_fds=True)
            print('HOST_USER_TIMER203_ARMED');return
        if s.get('phase')!='ARMED':return
        deadline=s['deadline']
    time.sleep(max(0,deadline-time.monotonic()))
    with (STATE/'lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        current=json.loads((STATE/'state.json').read_text())
        if current!=s:return
        if s['boot']!=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip():raise RuntimeError('host reboot: NOT reboot persistent')
        s['phase']='RUNNING';save(s)
    try:s['guest_rc']=serial(s['operation'],s['sha256']);s['phase']='COMMAND_DONE' if s['guest_rc']==0 else 'FAILED'
    except Exception as e:s['phase']='FAILED';s['error']=type(e).__name__
    s['finished_utc']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
    with (STATE/'lock').open('a') as lock:fcntl.flock(lock,fcntl.LOCK_EX);save(s)
    print(json.dumps(s))
if __name__=='__main__':main()
