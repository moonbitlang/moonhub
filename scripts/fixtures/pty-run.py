"""Exercise a real terminal prompt without depending on platform-specific script(1)."""
import errno
import os
import pty
import select
import signal
import sys
import time

answer, *command = sys.argv[1:]
pid, terminal = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
deadline = time.monotonic() + 25
pending = b""
answered = False
try:
    while time.monotonic() < deadline:
        if not select.select([terminal], [], [], 0.1)[0]:
            continue
        try:
            chunk = os.read(terminal, 8192)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        pending = (pending + chunk)[-8192:]
        if not answered and b"Continue upgrade? [y/N]" in pending:
            os.write(terminal, answer.encode())
            answered = True
    else:
        os.killpg(pid, signal.SIGKILL)
        raise RuntimeError("interactive fixture timed out")
finally:
    os.close(terminal)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
