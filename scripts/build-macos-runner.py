#!/usr/bin/env python3
"""Build the guest bundle on Apple Silicon. Does not install or modify the host."""
import argparse, hashlib, json, os, pathlib, platform, re, shutil, subprocess, tarfile, tempfile, urllib.request
root=pathlib.Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',default='.tmp/macos-runner');a=p.parse_args()
assert platform.system()=='Darwin' and platform.machine()=='arm64'
output=(root/a.output).resolve();assert not output.exists(),'Output must be a new directory'
def run(*args,**kw):return subprocess.check_output(args,cwd=root,text=True,**kw)
pin=re.search(r'^ARG MOONBIT_VERSION=(.+)$',(root/'deploy/base.Dockerfile').read_text(),re.M)[1]
assert run('moonc','-v').split()[0]=='v'+pin,'Select the production MoonBit toolchain first'
os.environ['MACOSX_DEPLOYMENT_TARGET']='14.0'
build=root/'.tmp/macos-native-14'
subprocess.check_call(['moon','build','--strip','-j','1','--deny-warn','--target-dir',str(build),'cmd/moonhub-runner'],cwd=root)
for name in ['bin','lib','actions','licenses']:(output/name).mkdir(parents=True)
shutil.copy2(build/'native/debug/build/cmd/moonhub-runner/moonhub-runner.exe',output/'bin/moonhub-runner')
subprocess.check_call(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','runner/step-launcher.c','-o',str(output/'bin/moonhub-runner-step')],cwd=root)
# Bundle non-system dylibs and rewrite references to sibling files, including
# transitive dependencies. A guest must not depend on the build host's Homebrew.
queue=[output/'bin/moonhub-runner'];seen=set()
while queue:
 binary=queue.pop()
 for line in run('otool','-L',str(binary)).splitlines()[1:]:
  library=line.strip().split(' (')[0]
  if not library.startswith('/') or library.startswith(('/usr/lib/','/System/')):continue
  source=pathlib.Path(library);target=output/'lib'/source.name
  if source.name not in seen:
   seen.add(source.name);shutil.copy2(source,target);target.chmod(0o755);queue.append(target)
   subprocess.check_call(['install_name_tool','-id','@loader_path/'+target.name,str(target)])
  subprocess.check_call(['install_name_tool','-change',library,'@loader_path/'+target.name,str(binary)])
for library in (output/'lib').glob('*.dylib'):shutil.copy2(library,output/'bin'/library.name)
subprocess.check_call(['npm','ci','--prefix','runner/actions','--omit=dev','--ignore-scripts','--no-audit','--no-fund'],cwd=root)
for file in (root/'runner/actions').glob('*.mjs'):shutil.copy2(file,output/'actions'/file.name)
shutil.copytree(root/'runner/actions/node_modules',output/'actions/node_modules')
shutil.copy2(root/'deploy/macos/guest.mjs',output/'macos-guest.mjs');shutil.copy2(root/'deploy/macos/install-guest.sh',output/'install-guest.sh')
shutil.copy2(root/'LICENSE',output/'licenses/MoonHub.txt');shutil.copy2(root/'vendor/yaml/LICENSE',output/'licenses/yaml.txt')
pins=json.loads((root/'deploy/macos/runtime.json').read_text())
with tempfile.TemporaryDirectory() as tmp:
 for key in ['node24','node20']:
  item=pins[key];archive=pathlib.Path(tmp)/(key+'.tar.xz');urllib.request.urlretrieve(item['url'],archive)
  assert hashlib.sha256(archive.read_bytes()).hexdigest()==item['sha256'],'Checksum mismatch: '+key
  with tarfile.open(archive) as tar:tar.extractall(pathlib.Path(tmp)/key,filter='data')
  directory=next((pathlib.Path(tmp)/key).iterdir());shutil.copy2(directory/'bin/node',output/'bin'/('node' if key=='node24' else 'node20'))
  shutil.copy2(directory/'LICENSE',output/'licenses'/(key+'.txt'))
for binary in (output/'bin').iterdir():subprocess.check_call(['codesign','--force','--sign','-',str(binary)])
(output/'runtime.json').write_text(json.dumps(pins,indent=2)+'\n')
print(output)
