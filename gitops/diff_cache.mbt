///|
priv enum DiffCacheValue {
  Manifest(Array[DiffFile])
  Document(String)
}

///|
// Conservative retained-memory estimates, in bytes, not serialized UTF-8 size
// or process RSS. Count shared strings again; exclude transient calculation,
// deserialization and map-rebuild allocations. All arithmetic widens to Int64
// before multiplying. Strings retain UTF-16 code units plus a 32-byte header.
fn diff_string_bytes(value : String) -> Int64 {
  32L + 2L * value.length().to_int64()
}

///|
async fn DiffCacheValue::retained_bytes(self : DiffCacheValue) -> Int64 {
  match self {
    Document(serialized) => diff_string_bytes(serialized)
    Manifest(files) => {
      // Array/header: 64 bytes plus 8 bytes per allocated reference slot.
      let mut size = 64L + 8L * files.capacity().to_int64()
      for i, file in files {
        if i % 256 == 0 {
          @async.sleep(0)
        }
        // File/option overhead: 128 bytes, plus every retained string field.
        size += 128L +
          diff_string_bytes(file.id) +
          diff_string_bytes(file.status) +
          diff_string_bytes(file.old_path) +
          diff_string_bytes(file.new_path) +
          diff_string_bytes(file.old_mode) +
          diff_string_bytes(file.new_mode) +
          diff_string_bytes(file.old_blob) +
          diff_string_bytes(file.new_blob)
        if file.path_error is Some(message) {
          size += diff_string_bytes(message)
        }
      }
      size
    }
  }
}

///|
fn DiffExecutor::cache_index_bytes(self : DiffExecutor) -> Int64 {
  // Index/header: 64 bytes plus 16 bytes per reserved entry, allowing for
  // unused buckets. Reserve entries explicitly instead of observing the map's
  // private bucket count. Empty caches are uncharged.
  if self.cache.is_empty() {
    0L
  } else {
    64L + 16L * self.cache_reserved_entries.to_int64()
  }
}

///|
fn DiffExecutor::resize_cache(
  self : DiffExecutor,
  reserved_entries : Int32,
) -> Unit {
  let resized = Map([], capacity=reserved_entries)
  for key, entry in self.cache {
    resized[key] = entry
  }
  self.cache = resized
  self.cache_reserved_entries = reserved_entries
}

///|
fn DiffExecutor::shrink_cache(self : DiffExecutor) -> Unit {
  if self.cache.is_empty() {
    self.resize_cache(4)
    self.cache_bytes = 0L
  } else if self.cache_reserved_entries.to_int64() >
    (4L * self.cache.length().to_int64()).max(4L) {
    self.cache_bytes -= self.cache_index_bytes()
    self.resize_cache(self.cache.length().next_power_of_two().max(4))
    self.cache_bytes += self.cache_index_bytes()
  }
}

///|
fn DiffExecutor::observe_diff(
  self : DiffExecutor,
  fields : Map[String, Json],
) -> Unit {
  fields["cache_entries"] = Json(self.cache.length())
  fields["cache_bytes"] = Json(self.cache_bytes.to_string())
  fields["cache_limit_bytes"] = Json(self.cache_limit_bytes.to_string())
  fields["cache_evictions_total"] = Json(self.cache_evictions.to_string())
  fields["cache_skips_total"] = Json(self.cache_skips.to_string())
  fields["cache_hits_total"] = Json(self.cache_hits)
  fields["coalesced_requests_total"] = Json(self.coalesced_requests.to_string())
  (self.observe)(Json(fields))
}

///|
fn DiffExecutor::cached(
  self : DiffExecutor,
  key : String,
  phase : String,
) -> DiffCacheValue? {
  // The linked hash map supports average O(1) lookup, refresh and eviction.
  // Removing before inserting refreshes LRU order without growing the index.
  guard self.cache.remove_and_get(key) is Some(entry) else { return None }
  self.cache[key] = entry
  self.cache_hits += 1
  self.observe_diff({ "event": "diff", "phase": phase, "cache": "hit" })
  Some(entry.0)
}

///|
fn DiffExecutor::cache_result(
  self : DiffExecutor,
  key : String,
  value : DiffCacheValue,
  value_bytes : Int64,
) -> Unit {
  // Entry/link/tuple overhead: 128 bytes, plus key and value. The smallest
  // retained index reserves four entries (128 bytes including its header).
  let size = 128L + diff_string_bytes(key) + value_bytes
  // Decide before touching the map, including a previous value at this key.
  if size > self.cache_limit_bytes - 128L {
    self.cache_skips += 1
    return
  }
  self.cache_bytes -= self.cache_index_bytes()
  if self.cache.remove_and_get(key) is Some((_, old_size)) {
    self.cache_bytes -= old_size
  }
  if self.cache.length() == self.cache_reserved_entries {
    self.resize_cache(self.cache_reserved_entries * 2)
  }
  self.cache[key] = (value, size)
  self.cache_bytes += size + self.cache_index_bytes()
  // All mutations and compaction are synchronous: other tasks only see a
  // complete cache whose entries and reserved index estimate fit the budget.
  self.shrink_cache()
  while self.cache_bytes > self.cache_limit_bytes {
    let (oldest, (_, old_size)) = self.cache.iter().next().unwrap()
    self.cache.remove(oldest)
    self.cache_bytes -= old_size
    self.cache_evictions += 1
    self.shrink_cache()
  }
}
