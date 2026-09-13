#!/usr/bin/env python3
"""Independent HTTP clients and a pinned real intermediary, on loopback only."""
from checks import require
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import selectors
import socket
import subprocess
import tempfile
import time
from contextlib import contextmanager
from dune_env import ROOT, configuration, command
from evidence import source_hash, record

dune,env,_=configuration()
version=env['HARNESS_COMPILER']
nginx=ROOT/'.toolchain/nginx/sbin/nginx'
@contextmanager
def backend(runtime,details=False):
    binary=ROOT/f'_build-pkg-{version}/default/test/interop/{runtime}_server.exe'
    with tempfile.TemporaryFile() as errors:
        p=subprocess.Popen([str(binary)],stdout=subprocess.PIPE,stderr=errors)
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(p.stdout,selectors.EVENT_READ)
                require(ready.select(10), 'backend readiness timeout')
            line=p.stdout.readline()
            require(line.strip().isdigit(), ('backend did not publish port',line))
            yield (int(line),p.pid) if details else int(line)
            require(p.poll() is None, 'backend exited unexpectedly')
        finally:
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
@contextmanager
def proxy(upstream,buffering):
    with tempfile.TemporaryDirectory(prefix='httpkit-nginx-') as directory:
        root=Path(directory)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0));port=reservation.getsockname()[1]
        config=f'''daemon off;
master_process off;
error_log stderr warn;
pid {root}/nginx.pid;
events {{ worker_connections 128; }}
http {{ access_log off; client_body_temp_path {root}/body; proxy_temp_path {root}/proxy;
server {{ listen 127.0.0.1:{port};
location / {{ proxy_pass http://127.0.0.1:{upstream}; proxy_http_version 1.1;
proxy_set_header Host $http_host; proxy_set_header Connection "";
proxy_request_buffering {buffering}; proxy_buffering {buffering}; }} }} }}
'''
        (root/'nginx.conf').write_text(config)
        with tempfile.TemporaryFile() as errors:
            p=subprocess.Popen([str(nginx),'-p',str(root)+'/', '-c',str(root/'nginx.conf')],stderr=errors,stdout=subprocess.DEVNULL)
            try:
                deadline=time.monotonic()+10
                while True:
                    if p.poll() is not None:
                        errors.seek(0);raise RuntimeError(errors.read().decode())
                    try:
                        with socket.create_connection(('127.0.0.1',port),timeout=.2):break
                    except OSError:
                        if time.monotonic()>=deadline:raise
                        time.sleep(.01) # Retry a checked readiness condition, not a startup delay.
                yield port
            finally:
                p.terminate()
                try:p.wait(timeout=5)
                except subprocess.TimeoutExpired:p.kill();p.wait()
def expected(method,path,body):
    return f'{method} {path} {len(body)} {hashlib.md5(body).hexdigest()}\n'.encode()
def positive(port):
    count=0
    connection=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
    try:
        for method,path,body,chunked in [
            ('GET','/one',b'',False),('POST','/fixed',b'a'*100000,False),
            ('POST','/chunked',b'abc'*1000,True),('HEAD','/head',b'',False),
            ('GET','/after-head',b'',False)]:
            outgoing=[body[i:i+173] for i in range(0,len(body),173)] if chunked else body
            connection.request(method,path,body=outgoing,encode_chunked=chunked)
            response=connection.getresponse();payload=response.read()
            require(response.status==200, (method,path,response.status))
            require(payload==(b'' if method=='HEAD' else expected(method,path,body)), (method,path,payload))
            require([v for n,v in response.getheaders() if n.lower()=='set-cookie']==['a=1','b=2'], "interop.py: [v for n,v in response.getheaders() if n.lower()=='set-cookie']==['a=1','b=2']")
            count+=1
    finally:connection.close()
    # curl is an independently maintained native HTTP client, not our codec.
    result=subprocess.run(['curl','--silent','--show-error','--fail','--max-time','5',f'http://127.0.0.1:{port}/curl'],capture_output=True)
    require(result.returncode==0 and result.stdout==expected('GET','/curl',b''), result.stderr)
    return count+1
def exchange(port,data,half_close=False):
    with socket.create_connection(('127.0.0.1',port),timeout=5) as peer:
        peer.settimeout(5);peer.sendall(data)
        if half_close: peer.shutdown(socket.SHUT_WR)
        out=bytearray()
        while True:
            try:part=peer.recv(65536)
            except ConnectionResetError:break
            if not part:break
            out.extend(part)
            require(len(out)<1048576, 'unexpected response amplification')
        return bytes(out)
marker=b'GET /marker HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'
bad={
 'cl-te':b'POST /bad HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
 'duplicate-cl':b'POST /bad HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n',
 'signed-cl':b'POST /bad HTTP/1.1\r\nHost: x\r\nContent-Length: +0\r\n\r\n',
 'te-chain':b'POST /bad HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n',
 'obs-fold':b'GET /bad HTTP/1.1\r\nHost: x\r\nX: a\r\n b\r\n\r\n',
 'bad-chunk':b'POST /bad HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n',
}
def lane(port,name):
    count=positive(port);findings=[]
    for case,prefix in bad.items():
        result=exchange(port,prefix+marker)
        require(b'/marker' not in result, (name,case,'marker reached application',result))
        require(b' 200 ' not in result, (name,case,'malformed request accepted',result))
        findings.append({'case':case,'classification':'rejected_without_marker','response_status':result.split(b'\r\n',1)[0].decode('ascii','replace')[:80]})
    # Two valid pipelined requests must remain two ordered responses.
    wire=exchange(port,b'GET /first HTTP/1.1\r\nHost: x\r\n\r\n'+marker)
    require(wire.count(b'HTTP/1.1 200 ')==2 and wire.index(b'/first')<wire.index(b'/marker'), (name,wire))
    half=exchange(port,b'GET /half HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',half_close=True)
    require((b'/half' in half) if name.endswith('/direct') else (half==b'' or b'/half' in half), "interop.py: (b'/half' in half) if name.endswith('/direct') else (half==b'' or b'/half' in half)")
    return {'lane':name,'positive_requests':count,'pipeline_responses':2,'framing_cases':findings,
            'half_close':'response_completed' if b'/half' in half else 'proxy_cancelled_upstream_on_client_abort'}
def main():
    if not nginx.is_file(): raise SystemExit('Nginx missing: mise run setup:nginx')
    nginx_version=subprocess.check_output([str(nginx),'-v'],stderr=subprocess.STDOUT,text=True).strip()
    require(nginx_version=='nginx version: nginx/1.30.4', nginx_version)
    subprocess.run(command(dune,env,['build','test/interop/eio_server.exe','test/interop/lwt_server.exe']),cwd=ROOT,env=env,check=True,timeout=1800)
    start_hash=source_hash()
    results=[]
    for runtime in ['eio','lwt']:
        with backend(runtime) as port:
            results.append(lane(port,runtime+'/direct'))
            for buffering in ['on','off']:
                with proxy(port,buffering) as proxy_port:results.append(lane(proxy_port,runtime+'/nginx-buffering-'+buffering))
    require(source_hash()==start_hash, 'sources changed during interop')
    record('interop-'+version+'.json',{'status':'PASS','compiler':version,'nginx':nginx_version,'curl':subprocess.check_output(['curl','--version'],text=True).splitlines()[0],
        'python':platform.python_version(),'results':results,'limitations':['One pinned intermediary; TLS, HTTP/2 translation and long soak are not covered.']})
    print(json.dumps({'status':'PASS','lanes':len(results),'framing_checks':len(results)*len(bad),'positive_requests':sum(r['positive_requests'] for r in results)},indent=2))

if __name__=='__main__': main()
