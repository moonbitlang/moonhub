///|
priv struct Parser {
  source : String
  mut offset : Int32
}

///|
priv suberror InvalidPage

///|
fn Parser::starts(self : Parser, text : String) -> Bool {
  self.source[self.offset:].has_prefix(text)
}

///|
fn Parser::spaces(self : Parser) -> Unit {
  while self.offset < self.source.length() &&
        self.source[self.offset] is (' ' | 10 | 13 | 9) {
    self.offset += 1
  }
}

///|
fn Parser::name(self : Parser) -> String raise {
  let start = self.offset
  while self.offset < self.source.length() &&
        !(self.source[self.offset] is (' ' | 10 | 13 | 9 | '/' | '>' | '=')) {
    self.offset += 1
  }
  guard start < self.offset else { raise InvalidPage }
  self.source[start:self.offset].to_owned().to_lower()
}

///|
fn decode_entities(text : String) -> String {
  // These are the entities emitted by Moonback's HTML builder. Decode ampersand
  // last so an escaped literal such as &amp;lt; is decoded exactly once.
  text
  .replace_all(old="&lt;", new="<")
  .replace_all(old="&gt;", new=">")
  .replace_all(old="&quot;", new="\"")
  .replace_all(old="&#39;", new="'")
  .replace_all(old="&amp;", new="&")
}

///|
fn void_element(tag : String) -> Bool {
  match tag {
    "area"
    | "base"
    | "br"
    | "col"
    | "embed"
    | "hr"
    | "img"
    | "input"
    | "link"
    | "meta"
    | "param"
    | "source"
    | "track"
    | "wbr" => true
    _ => false
  }
}

///|
fn Parser::nodes(
  self : Parser,
  closing : String?,
  depth : Int32,
) -> Array[Node] raise {
  guard depth < 128 else { raise InvalidPage }
  let nodes = []
  while self.offset < self.source.length() {
    if self.starts("<!--") {
      guard self.source[self.offset + 4:].find("-->") is Some(end) else {
        raise InvalidPage
      }
      self.offset += 4 + end + 3
    } else if self.starts("<!") {
      guard self.source[self.offset:].find(">") is Some(end) else {
        raise InvalidPage
      }
      self.offset += end + 1
    } else if self.starts("</") {
      self.offset += 2
      let tag = self.name()
      self.spaces()
      guard self.starts(">") && closing == Some(tag) else { raise InvalidPage }
      self.offset += 1
      return nodes
    } else if self.starts("<") {
      self.offset += 1
      let tag = self.name()
      let attributes = []
      self.spaces()
      while !self.starts(">") && !self.starts("/>") {
        let name = self.name()
        self.spaces()
        let value = if self.starts("=") {
          self.offset += 1
          self.spaces()
          guard self.offset < self.source.length() else { raise InvalidPage }
          let quote = self.source[self.offset]
          if quote is (34 | 39) {
            self.offset += 1
            let start = self.offset
            while self.offset < self.source.length() &&
                  self.source[self.offset] != quote {
              self.offset += 1
            }
            guard self.offset < self.source.length() else { raise InvalidPage }
            let value = self.source[start:self.offset].to_owned()
            self.offset += 1
            decode_entities(value)
          } else {
            let start = self.offset
            while self.offset < self.source.length() &&
                  !(self.source[self.offset] is (' ' | 10 | 13 | 9 | '>')) {
              self.offset += 1
            }
            decode_entities(self.source[start:self.offset].to_owned())
          }
        } else {
          ""
        }
        attributes.push((name, value))
        self.spaces()
      }
      let self_closing = self.starts("/>")
      self.offset += if self_closing { 2 } else { 1 }
      let children = if self_closing || void_element(tag) {
        []
      } else if tag == "script" ||
        tag == "style" ||
        tag == "textarea" ||
        tag == "title" {
        let ending = "</\{tag}>"
        guard self.source[self.offset:].find(ending) is Some(end) else {
          raise InvalidPage
        }
        let text = self.source[self.offset:self.offset + end].to_owned()
        self.offset += end + ending.length()
        [
          Text(
            if tag == "script" || tag == "style" {
              text
            } else {
              decode_entities(text)
            },
          ),
        ]
      } else {
        self.nodes(Some(tag), depth + 1)
      }
      nodes.push(Element(tag, attributes, children))
    } else {
      let start = self.offset
      while self.offset < self.source.length() &&
            self.source[self.offset] != '<' {
        self.offset += 1
      }
      nodes.push(
        Text(decode_entities(self.source[start:self.offset].to_owned())),
      )
    }
  }
  guard closing is None else { raise InvalidPage }
  nodes
}

///|
/// Adapter for trusted HTML produced by existing MoonHub templates, not a
/// general-purpose HTML parser. Reject malformed output rather than guessing.
pub fn parse_page(source : String) -> Page raise {
  let parser = Parser::{ source, offset: 0, }
  let nodes = parser.nodes(None, 0)
  for node in nodes {
    if node is Element("html", _, children) {
      let mut head = None
      let mut body = None
      for child in children {
        match child {
          Element("head", _, nodes) => head = Some(nodes)
          Element("body", _, nodes) => body = Some(nodes)
          _ => ()
        }
      }
      guard head is Some(head) && body is Some(body) else { raise InvalidPage }
      return { head, body, }
    }
  }
  raise InvalidPage
}
