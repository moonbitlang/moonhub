///|
// The file and constructor stay private: ownership passes to the factory and
// callers can only release the resulting handle, never relock its file.
struct FileLock {
  file : @fs.File
  mut held : Bool
  mut closed : Bool
}

///|
/// Take ownership of an open file and wait for its lock. On failure, timeout or
/// cancellation, release any acquired lock and close the file. The caller must
/// not use the file after passing it here, including through aliases.
pub async fn acquire(
  file : @fs.File,
  mode~ : @fs.Lock = Exclusive,
  timeout_ms? : Int32,
) -> FileLock {
  let lock = { file, held: false, closed: false, }
  errdefer lock.close()
  async fn take_lock() -> Unit {
    file.lock(mode)
    // Record ownership before leaving with_timeout: its scope may still raise
    // after this callback succeeds, in which case errdefer must also unlock.
    lock.held = true
  }
  match timeout_ms {
    Some(ms) => @async.with_timeout(ms, take_lock)
    None => take_lock()
  }
  lock
}

///|
/// Take ownership of an open file and try to lock it immediately. Contention
/// closes the file and returns None; other errors close it and propagate.
/// The caller must not use the file after passing it here.
pub fn try_acquire(
  file : @fs.File,
  mode~ : @fs.Lock = Exclusive,
) -> FileLock? raise {
  errdefer file.close()
  if file.try_lock(mode) {
    Some({ file, held: true, closed: false, })
  } else {
    file.close()
    None
  }
}

///|
/// Release the lock before closing its file, even if a child process or dup()
/// retains the same open file description. Repeated closes, including through
/// aliases, are harmless.
pub fn FileLock::close(self : FileLock) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  defer self.file.close()
  if self.held {
    self.file.unlock()
  }
}
