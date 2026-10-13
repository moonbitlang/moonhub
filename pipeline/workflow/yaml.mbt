///|
priv struct YamlFrame {
  mapping : Bool
  mut key : Bool
}

///|
priv struct YamlGuard {
  frames : Array[YamlFrame]
  mut documents : Int32
  mut nodes : Int32
}

///|
impl @yaml.MarkedEventReceiver for YamlGuard with fn on_event(self, event, mark) {
  self.check_event(event) catch {
    InvalidWorkflow(message) => raise @yaml.YamlError(mark~, info=message)
  }
}

///|
fn YamlGuard::check_event(
  self : YamlGuard,
  event : @yaml.Event,
) -> Unit raise InvalidWorkflow {
  match event {
    DocumentStart => {
      self.documents += 1
      guard self.documents == 1 else {
        raise InvalidWorkflow("exactly one YAML document is required")
      }
    }
    Alias(..) => raise InvalidWorkflow("YAML aliases are not supported")
    Scalar(value~, id~, tag~, ..) => {
      self.check_node(id, tag)
      guard !value.contains("\u{0000}") else {
        raise InvalidWorkflow("YAML scalar contains a NUL character")
      }
      if self.frames.last() is Some(frame) && frame.mapping && frame.key {
        guard !value.is_empty() && value != "<<" else {
          raise InvalidWorkflow(
            "empty keys and YAML merge keys are not supported",
          )
        }
      }
      self.finish_node()
    }
    SequenceStart(id~, tag~) | MappingStart(id~, tag~) => {
      self.check_node(id, tag)
      if self.frames.last() is Some(frame) && frame.mapping && frame.key {
        raise InvalidWorkflow("mapping keys must be strings")
      }
      guard self.frames.length() < 32 else {
        raise InvalidWorkflow("YAML nesting exceeds 32 levels")
      }
      self.frames.push({ mapping: event is MappingStart(..), key: true, })
    }
    SequenceEnd | MappingEnd => {
      ignore(self.frames.pop())
      self.finish_node()
    }
    _ => ()
  }
}

///|
fn YamlGuard::check_node(
  self : YamlGuard,
  anchor : Int32,
  tag : @yaml.Tag?,
) -> Unit raise InvalidWorkflow {
  guard anchor == 0 && tag is None else {
    raise InvalidWorkflow("YAML anchors and explicit tags are not supported")
  }
  self.nodes += 1
  guard self.nodes <= 8192 else {
    raise InvalidWorkflow("YAML exceeds 8192 nodes")
  }
}

///|
fn YamlGuard::finish_node(self : YamlGuard) -> Unit {
  if self.frames.last() is Some(frame) && frame.mapping {
    frame.key = !frame.key
  }
}

///|
fn read_yaml(source : String) -> @yaml.Yaml raise InvalidWorkflow {
  guard @utf8.encode(source).length() <= max_source_bytes else {
    raise InvalidWorkflow("workflow exceeds 64 KiB")
  }
  guard !source.contains("\u{0000}") else {
    raise InvalidWorkflow("workflow contains a NUL character")
  }
  let guard_ : YamlGuard = { frames: [], documents: 0, nodes: 0, }
  // Reject excessive nesting or aliases before the parser descends further or
  // the standard loader constructs a tree.
  @yaml.Parser::new(source).load(guard_, true) catch {
    @yaml.YamlError(mark~, info~) =>
      raise InvalidWorkflow(
        "invalid YAML at line \{mark.line}, column \{mark.col + 1}: \{info}",
      )
  }
  let documents = @yaml.Yaml::load_from_string(source) catch {
    @yaml.YamlError(mark~, info~) =>
      raise InvalidWorkflow(
        "invalid YAML at line \{mark.line}, column \{mark.col + 1}: \{info}",
      )
  }
  guard documents.length() == 1 else {
    raise InvalidWorkflow("exactly one YAML document is required")
  }
  documents[0]
}
