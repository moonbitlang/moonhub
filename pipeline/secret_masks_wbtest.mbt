///|
test "overlapping masks retain the whole match when a suffix is pending" {
  assert_eq(mask_log("ababa!", ["abab", "baba"]), ("***!", ""))
  let (ready, pending) = mask_log("before abcd", ["abcd", "cdef"])
  assert_eq(ready, "before ")
  assert_eq(pending, "abcd")
  assert_eq(mask_log(pending + "X", ["abcd", "cdef"]), ("***X", ""))
  assert_eq(mask_log(pending + "ef!", ["abcd", "cdef"]), ("***!", ""))
  assert_eq(
    mask_log("😀密钥😀!", ["密钥", "钥😀"]),
    ("😀***!", ""),
  )
}

///|
test "masking handles maximum length repeated prefixes without rescanning each start" {
  let mask = "a".repeat(16383) + "b"
  let chunk = "a".repeat(8192)
  let mut ready = 0
  let mut pending = ""
  for _ in 0..<128 {
    let (output, tail) = mask_log(pending + chunk, [mask])
    ready += output.length()
    pending = tail
  }
  assert_eq(pending, "a".repeat(16383))
  assert_eq(ready + pending.length(), 1048576)
  assert_eq(mask_log(pending + "b!", [mask]), ("***!", ""))
  let (_, overlap) = mask_log("a".repeat(8192), ["aa", "aaa"])
  assert_true(overlap.length() <= 4)
  let (masked, next) = mask_log(overlap + "!", ["aa", "aaa"])
  assert_eq(masked, "***!")
  assert_eq(next, "")
}

///|
test "multi pattern matching agrees with an independent direct comparison oracle" {
  let words = [
    "a", "b", "aa", "ab", "ba", "bb", "aaa", "aab", "aba", "abb", "baa", "bab", "bba",
    "bbb",
  ]
  for first in words {
    for second in words {
      let masks = [first, second]
      for
        text in ["", "a", "aba", "baba", "abbba!", "before aaababbab", "ababa"] {
        let covered : Array[Bool] = Array::make(text.length(), false)
        let matches : Array[(Int32, Int32)] = []
        let mut cut = text.length()
        for mask in masks {
          for start = 0; start < text.length(); start = start + 1 {
            if text[start:].has_prefix(mask) {
              matches.push((start, start + mask.length()))
              for i = start; i < start + mask.length(); i = i + 1 {
                covered[i] = true
              }
            }
          }
          for length = 1
              length < mask.length() && length <= text.length()
              length = length + 1 {
            if text.has_suffix(mask[:length]) {
              cut = Int32::min(cut, text.length() - length)
            }
          }
        }
        let original_cut = cut
        for (start, end) in matches {
          if start < original_cut && end > original_cut {
            cut = Int32::min(cut, start)
          }
        }
        let output = StringBuilder()
        let mut inside = false
        for index = 0; index < cut; index = index + 1 {
          if covered[index] {
            if !inside {
              output.write_string("***")
            }
            inside = true
          } else {
            output.write_string(text[index:index + 1].to_owned())
            inside = false
          }
        }
        let result = mask_log(text, masks)
        // Adjacent independent matches may produce separate replacement markers.
        let mut canonical = result.0
        while canonical.contains("******") {
          canonical = canonical.replace_all(old="******", new="***")
        }
        assert_eq(canonical, output.to_string())
        assert_eq(result.1, text[cut:].to_owned())
        let complete = StringBuilder()
        let mut inside = false
        for index = 0; index < text.length(); index = index + 1 {
          if covered[index] {
            if !inside {
              complete.write_string("***")
            }
            inside = true
          } else {
            complete.write_string(text[index:index + 1].to_owned())
            inside = false
          }
        }
        complete.write_string("!")
        for split = 0; split <= text.length(); split = split + 1 {
          let (first, tail) = mask_log(text[:split].to_owned(), masks)
          let (second, rest) = mask_log(
            tail + text[split:].to_owned() + "!",
            masks,
          )
          assert_eq(rest, "")
          let mut joined = first + second
          while joined.contains("******") {
            joined = joined.replace_all(old="******", new="***")
          }
          assert_eq(joined, complete.to_string())
        }
      }
    }
  }
}
