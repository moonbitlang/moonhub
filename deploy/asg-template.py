#!/usr/bin/env python3
"""Create a runner-image-pinned version of an existing dedicated launch template.

Use --new-name only before provider enrollment: the controller pins the template ID.
Subsequent releases keep that ID and select the returned numeric version in UI.
"""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--region', required=True)
p.add_argument('--template', required=True)
p.add_argument('--source-version', required=True, type=int)
p.add_argument('--image', required=True)
p.add_argument('--new-name')
a = p.parse_args()
if not re.fullmatch(r'[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9_./-]+:[a-f0-9]{12,40}', a.image):
    p.error('Use a commit-addressed private ECR image')
if not re.fullmatch(r'[a-z0-9-]+', a.region) or a.source_version < 1:
    p.error('Invalid region or numeric template version')

def aws(*args):
    output = subprocess.check_output(['aws', *args, '--region', a.region, '--output', 'json', '--no-cli-pager'], text=True)
    return json.loads(output) if output.strip() else {}

source = aws('ec2', 'describe-launch-template-versions', '--launch-template-id', a.template,
             '--versions', str(a.source_version))['LaunchTemplateVersions'][0]['LaunchTemplateData']
if source.get('MetadataOptions', {}).get('HttpTokens') != 'required' or source['MetadataOptions'].get('HttpPutResponseHopLimit') != 1:
    raise SystemExit('Template must enforce IMDSv2 with hop limit 1')
script = Path(__file__).with_name('worker-bootstrap.sh').read_text().replace('@RUNNER_IMAGE@', a.image).replace('@AWS_REGION@', a.region)
source['UserData'] = base64.b64encode(script.encode()).decode()
description = 'MoonHub runner ' + a.image.rsplit(':', 1)[1]
if a.new_name:
    result = aws('ec2', 'create-launch-template', '--launch-template-name', a.new_name,
                 '--version-description', description, '--launch-template-data', json.dumps(source),
                 '--tag-specifications', json.dumps([{'ResourceType':'launch-template', 'Tags':[{'Key':'Application','Value':'moonhub-runner'}]}]))['LaunchTemplate']
    print(json.dumps({'template':result['LaunchTemplateId'], 'version':str(result['LatestVersionNumber'])}))
else:
    result = aws('ec2', 'create-launch-template-version', '--launch-template-id', a.template,
                 '--version-description', description, '--launch-template-data', json.dumps(source))['LaunchTemplateVersion']
    print(json.dumps({'template':result['LaunchTemplateId'], 'version':str(result['VersionNumber'])}))
