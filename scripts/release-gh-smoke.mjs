import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawn,spawnSync} from 'node:child_process';

const input=JSON.parse(await new Promise((resolve,reject)=>{let s='';process.stdin.setEncoding('utf8');process.stdin.on('data',x=>s+=x).on('end',()=>resolve(s)).on('error',reject)}));
const tmp=await fs.mkdtemp(path.join(os.tmpdir(),'moonhub-release-gh-'));
let proxy;
try {
  const socket=path.join(tmp,'gh.sock');
  const base='https://moonhub.local.test';
  proxy=http.createServer((req,res)=>{
    const upstream=http.request({host:'127.0.0.1',port:input.port,path:req.url,method:req.method,headers:{...req.headers,host:`127.0.0.1:${input.port}`}},response=>{
      const chunks=[];
      if(response.headers['content-type']?.includes('application/json')){
        response.on('data',x=>chunks.push(x));response.on('end',()=>{
          const body=Buffer.from(Buffer.concat(chunks).toString().replaceAll('https://moonhub.test',base));
          const headers={...response.headers,'content-length':String(body.length)};if(headers.link)headers.link=headers.link.replaceAll('https://moonhub.test',base);delete headers['transfer-encoding'];res.writeHead(response.statusCode,headers);res.end(body);
        });
      }else{res.writeHead(response.statusCode,response.headers);response.pipe(res);}
    });upstream.on('error',()=>{res.writeHead(502);res.end()});req.pipe(upstream);
  });
  await new Promise(resolve=>proxy.listen(socket,resolve));
  const host=new URL(base).host;const config=path.join(tmp,'gh');await fs.mkdir(config,{mode:0o700});
  await fs.writeFile(path.join(config,'config.yml'),JSON.stringify({version:'1',http_unix_socket:socket}),{mode:0o600});
  await fs.writeFile(path.join(config,'hosts.yml'),JSON.stringify({[host]:{oauth_token:input.token,git_protocol:'https',user:'alice',users:{alice:{oauth_token:input.token}}}}),{mode:0o600});
  const gh=async(...args)=>await new Promise((resolve,reject)=>{
    const child=spawn('gh',args,{cwd:tmp,env:{...process.env,GH_HOST:host,GH_CONFIG_DIR:config,GH_PROMPT_DISABLED:'1',GH_NO_UPDATE_NOTIFIER:'1',GH_ENTERPRISE_TOKEN:'',GITHUB_ENTERPRISE_TOKEN:''},stdio:['ignore','pipe','pipe']});
    let stdout='',stderr='';child.stdout.on('data',x=>stdout+=x);child.stderr.on('data',x=>stderr+=x);
    child.on('error',reject);child.on('exit',code=>code===0?resolve(stdout):reject(Error(`gh ${args.slice(0,2).join(' ')} failed: ${stderr.replaceAll(input.token,'[REDACTED]')}`)));
  });
  const repo='alice/demo',tag='v9.8.7';
  await gh('release','create',tag,'--repo',repo,'--draft','--target',input.sha,'--title','Smoke release','--notes','Bounded release validation');
  await fs.writeFile(path.join(tmp,'app.zip'),Buffer.alloc(9*1024*1024,67));
  await gh('release','upload',tag,'app.zip','--repo',repo,'--clobber');
  // Retry replaces only draft assets; then download through the real gh client.
  await fs.writeFile(path.join(tmp,'app.zip'),Buffer.from('final immutable release bytes'));
  await gh('release','upload',tag,'app.zip','--repo',repo,'--clobber');
  await fs.mkdir(path.join(tmp,'download'));
  await gh('release','download',tag,'--repo',repo,'--dir','download','--pattern','app.zip');
  assert.deepEqual(await fs.readFile(path.join(tmp,'download','app.zip')),Buffer.from('final immutable release bytes'));
  await gh('release','edit',tag,'--repo',repo,'--draft=false','--latest');
  const release=JSON.parse(await gh('api',`repos/${repo}/releases/latest`));
  assert.equal(release.target_commitish,input.sha);assert.equal(release.immutable,true);assert.equal(release.assets.length,1);assert.match(release.assets[0].digest,/^sha256:[0-9a-f]{64}$/);
  const all=JSON.parse(await gh('api','--paginate',`repos/${repo}/releases?per_page=1`));assert.equal(all.length,1);
  console.log(JSON.stringify({realGh:true,createDraft:true,streamUpload:true,replaceDraftAsset:true,download:true,publish:true,latest:true,pagination:true}));
}finally{
  if(proxy)await new Promise(resolve=>proxy.close(resolve));
  await fs.rm(tmp,{recursive:true,force:true});
}
