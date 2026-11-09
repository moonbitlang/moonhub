#!/usr/bin/env python3
"""Bound release images in the independent DinD daemon without pruning task data."""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

RESERVE_BYTES = 1024 ** 3
RESERVE_INODES = 65536
MANAGED_IMAGE = re.compile(r'moonhub-runner:([0-9a-f]{12})')


def docker(args, host=None):
    command = ['docker'] + (['-H', host] if host else []) + args
    return subprocess.check_output(command, text=True).strip()


def inspect_images(references, host=None):
    return json.loads(docker(['image', 'inspect', *references], host)) if references else []


def load_state(path):
    if os.path.islink(path):
        raise ValueError('Image retention state must not be a symbolic link')
    if not os.path.exists(path):
        return None
    with open(path) as source:
        state = json.load(source)
    if not isinstance(state, dict) or state.get('format') != 1 or not all(
        isinstance(state.get(key), str) and state[key] and not re.search(r'\s', state[key])
        for key in ['current', 'previous']
    ):
        raise ValueError('Invalid image retention state; preserve it and inspect before retrying')
    return state


def save_state(path, current, previous):
    # The controller state directory is already operator-owned and private.
    descriptor, temporary = tempfile.mkstemp(prefix='.deployed-images-', dir=os.path.dirname(path))
    try:
        with os.fdopen(descriptor, 'w') as destination:
            json.dump({'format': 1, 'current': current, 'previous': previous}, destination)
            destination.write('\n')
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def prune_images(host, references, candidate=None):
    # Protect immutable IDs too: a task or another tag may refer to the same image.
    protected = {image['Id'] for image in inspect_images(list(set(references)), host)}
    containers = docker(['ps', '-aq'], host).split()
    if containers:
        protected.update(container['Image'] for container in json.loads(docker(['inspect', *containers], host)))
    identifiers = list(set(docker(['image', 'ls', '-aq', '--no-trunc'], host).split()))
    for image in inspect_images(identifiers, host):
        if image['Id'] in protected or candidate in (image.get('RepoTags') or []):
            continue
        revision = (image.get('Config', {}).get('Labels') or {}).get('org.opencontainers.image.revision', '')
        if not re.fullmatch(r'[0-9a-f]{40}', revision):
            continue
        for tag in image.get('RepoTags') or []:
            match = MANAGED_IMAGE.fullmatch(tag)
            if match and revision.startswith(match[1]):
                print('Removing obsolete DinD release image: ' + tag, flush=True)
                # Never force removal: Docker must still reject a newly referenced image.
                docker(['image', 'rm', tag], host)


def data_directory(host):
    """Resolve DockerRootDir through the daemon container's real host mount."""
    info = json.loads(docker(['info', '--format', '{{json .}}'], host))
    root = info['DockerRootDir']
    socket = host.removeprefix('unix://')
    if not host.startswith('unix:///') or not root.startswith('/'):
        raise ValueError('Storage checks require the dedicated local Unix Docker socket')
    candidates = []
    identifiers = docker(['ps', '-q']).split()
    for container in json.loads(docker(['inspect', *identifiers])) if identifiers else []:
        if container['Config']['Hostname'] != info['Name']:
            continue
        mounts = container['Mounts']
        # Confirm this daemon's socket is in the matching container namespace.
        if not any(os.path.realpath(socket).startswith(os.path.realpath(mount['Source']).rstrip('/') + '/')
                   for mount in mounts):
            continue
        for mount in sorted(mounts, key=lambda value: len(value['Destination']), reverse=True):
            destination = mount['Destination'].rstrip('/')
            if root == destination or root.startswith(destination + '/'):
                candidates.append(os.path.join(mount['Source'], os.path.relpath(root, destination)))
                break
    if len(candidates) != 1:
        raise ValueError('Cannot uniquely resolve the DinD data mount; refusing a root-filesystem space guess')
    return os.path.realpath(candidates[0])


def check_space(host, image, directory):
    available = os.statvfs(directory)
    free_bytes = available.f_bavail * available.f_frsize
    free_inodes = available.f_favail
    # docker load can temporarily hold the archive and extracted layers together.
    source = inspect_images([image])[0]
    size = source['Size']
    revision = (source.get('Config', {}).get('Labels') or {}).get('org.opencontainers.image.revision', '')
    if not isinstance(size, int) or size <= 0 or not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Candidate image must have a size and full production revision label')
    loaded = docker(['image', 'ls', '--format', '{{.Repository}}:{{.Tag}}'], host).splitlines()
    matching = image in loaded and ((inspect_images([image], host)[0].get('Config', {}).get('Labels') or {})
                                   .get('org.opencontainers.image.revision') == revision)
    required = RESERVE_BYTES if matching else 2 * size + RESERVE_BYTES
    print(f'DinD storage {directory}: {free_bytes} bytes and {free_inodes} inodes free; '
          f'require {required} bytes and {RESERVE_INODES} inodes.', flush=True)
    if free_bytes < required or free_inodes < RESERVE_INODES:
        raise ValueError('Insufficient DinD import/task headroom; free obsolete images or enlarge its dedicated filesystem before retrying. Web remains unchanged')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'commit', 'check'])
    for name in ['socket', 'image', 'current', 'startup', 'state']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    state = load_state(args.state)
    protected = [args.image, args.current, args.startup]
    if args.operation in ['prepare', 'check']:
        directory = data_directory(args.socket)
        if args.operation == 'prepare' and state and state['current'] == args.current:
            # The target may not exist yet; only inspect protected installed images.
            prune_images(args.socket, [args.current, args.startup, state['previous']], args.image)
        elif args.operation == 'prepare':
            print('No matching successful-release journal; preserving existing DinD recovery images.', flush=True)
        check_space(args.socket, args.image, directory)
    else:
        if args.current == args.image:
            if not state or state['current'] != args.image:
                print('No previous successful release recorded; preserving existing DinD images.', flush=True)
                return
            previous = state['previous']
        else:
            previous = args.current
        # Persist before deleting anything, so interrupted cleanup is safe to retry.
        save_state(args.state, args.image, previous)
        prune_images(args.socket, protected + [previous])


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print('DinD image retention: ' + str(error), file=sys.stderr)
        sys.exit(1)
