#!/usr/bin/env python3
"""Render a systemd controller unit from operator-owned production settings."""
import os
import re
import sys


def unit_quote(value):
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError('Control characters are not allowed in systemd settings')
    return chr(34) + value.replace(chr(92), chr(92) * 2).replace(chr(34), chr(92) + chr(34)).replace('%', '%%').replace('$', '$$') + chr(34)


def render(env):
    args = ['/usr/local/bin/moonhub-runner', 'run', '--server', env['MOONHUB_SERVER'],
            '--name', env.get('MOONHUB_PROVIDER_NAME', 'asg'), '--mode', 'asg',
            '--registration-token-file', env['MOONHUB_REGISTRATION_TOKEN_FILE'],
            '--state-dir', env['MOONHUB_CONTROLLER_STATE_DIR'],
            '--aws', env.get('MOONHUB_AWS_CLI', '/usr/local/bin/aws'),
            '--region', env['MOONHUB_AWS_REGION'], '--asg', env['MOONHUB_ASG'],
            '--launch-template', env['MOONHUB_LAUNCH_TEMPLATE'],
            '--instance-types', env['MOONHUB_INSTANCE_TYPES'],
            '--parameter-prefix', env['MOONHUB_PARAMETER_PREFIX'],
            '--runner-image', env['MOONHUB_TASK_IMAGE']]
    if env.get('MOONHUB_SPOT_ASG'):
        args += ['--spot-asg', env['MOONHUB_SPOT_ASG']]
    return '''[Unit]
Description=MoonHub standalone ASG provider controller
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
UMask=0077
Environment=AWS_PAGER=
ExecStart=''' + ' '.join(map(unit_quote, args)) + '''
Restart=on-failure
RestartSec=65
TimeoutStopSec=35
MemoryMax=256M
CPUQuota=25%
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=''' + unit_quote(env['MOONHUB_CONTROLLER_STATE_DIR']) + '''

[Install]
WantedBy=multi-user.target
'''


def equivalent(installed, candidate):
    # Enrolled providers use the saved server configuration, so a new build's
    # runner-image bootstrap default does not itself change execution settings.
    image = '("--runner-image" )"[^"]*"'
    old, old_count = re.subn(image, lambda m: m.group(1) + '"<enrolled-runner-image>"', installed)
    new, new_count = re.subn(image, lambda m: m.group(1) + '"<enrolled-runner-image>"', candidate)
    return old_count == new_count == 1 and old == new


if __name__ == '__main__':
    candidate = render(os.environ)
    if len(sys.argv) == 3 and sys.argv[1] == '--matches':
        with open(sys.argv[2]) as installed:
            sys.exit(0 if equivalent(installed.read(), candidate) else 1)
    print(candidate, end='')
