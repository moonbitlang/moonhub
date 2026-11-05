///|
priv enum FilterToken {
  Literal(Char)
  Class(Array[(Char, Char)])
  Star
  GlobStar
  Directories
  Optional(FilterToken)
  Plus(FilterToken)
}

///|
fn filter_tokens(pattern : String) -> Array[FilterToken] raise InvalidWorkflow {
  let chars = pattern.to_array()
  guard chars.length() > 0 &&
    chars.length() <= 256 &&
    !pattern.contains("${{") &&
    chars.all(ch => ch.to_int() >= 32 && ch.to_int() != 127) else {
    raise InvalidWorkflow("invalid or oversized filter pattern")
  }
  let tokens : Array[FilterToken] = []
  let mut i = 0
  while i < chars.length() {
    let ch = chars[i]
    i += 1
    match ch {
      '\\' => {
        guard i < chars.length() else {
          raise InvalidWorkflow("unterminated filter escape")
        }
        tokens.push(Literal(chars[i]))
        i += 1
      }
      '*' =>
        if i < chars.length() && chars[i] == '*' {
          i += 1
          if i < chars.length() && chars[i] == '/' {
            i += 1
            tokens.push(Directories)
          } else {
            tokens.push(GlobStar)
          }
        } else {
          tokens.push(Star)
        }
      '[' => {
        let ranges : Array[(Char, Char)] = []
        while i < chars.length() && chars[i] != ']' {
          let first = chars[i]
          guard first.is_ascii_alphabetic() || first.is_ascii_digit() else {
            raise InvalidWorkflow(
              "filter classes require alphanumeric characters",
            )
          }
          i += 1
          if i + 1 < chars.length() && chars[i] == '-' && chars[i + 1] != ']' {
            let last = chars[i + 1]
            guard first <= last &&
              (
                (first >= 'a' && last <= 'z') ||
                (first >= 'A' && last <= 'Z') ||
                (first >= '0' && last <= '9')
              ) else {
              raise InvalidWorkflow("invalid filter character range")
            }
            ranges.push((first, last))
            i += 2
          } else {
            ranges.push((first, first))
          }
        }
        guard i < chars.length() && !ranges.is_empty() else {
          raise InvalidWorkflow("unterminated or empty filter class")
        }
        i += 1
        tokens.push(Class(ranges))
      }
      '?' | '+' => {
        guard tokens.pop() is Some(token) &&
          (token is Literal(_) || token is Class(_)) else {
          raise InvalidWorkflow(
            "filter quantifier requires a preceding character or class",
          )
        }
        tokens.push(if ch == '?' { Optional(token) } else { Plus(token) })
      }
      _ => tokens.push(Literal(ch))
    }
  }
  tokens
}

///|
fn FilterToken::accepts(self : FilterToken, ch : Char) -> Bool {
  match self {
    Literal(expected) => ch == expected
    Class(ranges) => ranges.any(range => ch >= range.0 && ch <= range.1)
    _ => false
  }
}

///|
// Finite-state matching, without recursive backtracking on untrusted patterns.
fn filter_match(pattern : String, value : String) -> Bool {
  let tokens = filter_tokens(pattern) catch { _ => return false }
  let chars = value.to_array()
  let mut states = Array::make(chars.length() + 1, false)
  states[0] = true
  for token in tokens {
    let next = Array::make(chars.length() + 1, false)
    match token {
      Star | GlobStar =>
        for i = 0; i <= chars.length(); i = i + 1 {
          if states[i] {
            next[i] = true
          }
          if i < chars.length() &&
            next[i] &&
            (token is GlobStar || chars[i] != '/') {
            next[i + 1] = true
          }
        }
      Directories => {
        let mut reachable = false
        for i = 0; i <= chars.length(); i = i + 1 {
          if states[i] {
            reachable = true
            next[i] = true
          }
          if reachable && i < chars.length() && chars[i] == '/' {
            next[i + 1] = true
          }
        }
      }
      Optional(atom) =>
        for i = 0; i <= chars.length(); i = i + 1 {
          if states[i] {
            next[i] = true
            if i < chars.length() && atom.accepts(chars[i]) {
              next[i + 1] = true
            }
          }
        }
      Plus(atom) =>
        for i = 0; i < chars.length(); i = i + 1 {
          if (states[i] || next[i]) && atom.accepts(chars[i]) {
            next[i + 1] = true
          }
        }
      _ =>
        for i = 0; i < chars.length(); i = i + 1 {
          if states[i] && token.accepts(chars[i]) {
            next[i + 1] = true
          }
        }
    }
    states = next
  }
  states[chars.length()]
}
