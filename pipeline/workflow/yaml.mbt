///|
priv struct YamlFrame {
  mapping : Bool
  mut key : Bool
  anchor : Int32
  mut nodes : Int32
  mut bytes : Int32
  mut depth : Int32
}

///|
priv struct YamlCost {
  nodes : Int32
  bytes : Int32
  depth : Int32
}

///|
priv struct YamlGuard {
  frames : Array[YamlFrame]
  anchors : Map[Int32, YamlCost]
  mut documents : Int32
  mut nodes : Int32
  mut bytes : Int32
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
    Alias(id~) => {
      guard self.anchors.get(id) is Some(cost) else {
        raise InvalidWorkflow("undefined or recursive YAML alias")
      }
      if self.frames.last() is Some(frame) && frame.mapping && frame.key {
        raise InvalidWorkflow("YAML aliases cannot be mapping keys")
      }
      self.charge(cost)
      self.finish_node(cost)
    }
    Scalar(value~, id~, tag~, ..) => {
      self.check_node(tag)
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
      let cost = { nodes: 1, bytes: @utf8.encode(value).length(), depth: 0, }
      self.charge(cost)
      if id > 0 {
        self.anchors[id] = cost
      }
      self.finish_node(cost)
    }
    SequenceStart(id~, tag~) | MappingStart(id~, tag~) => {
      self.check_node(tag)
      if self.frames.last() is Some(frame) && frame.mapping && frame.key {
        raise InvalidWorkflow("mapping keys must be strings")
      }
      guard self.frames.length() < 32 else {
        raise InvalidWorkflow("YAML nesting exceeds 32 levels")
      }
      self.charge({ nodes: 1, bytes: 0, depth: 1, })
      self.frames.push({
        mapping: event is MappingStart(..),
        key: true,
        anchor: id,
        nodes: 1,
        bytes: 0,
        depth: 1,
      })
    }
    SequenceEnd | MappingEnd => {
      let frame = self.frames.pop().unwrap()
      let cost = { nodes: frame.nodes, bytes: frame.bytes, depth: frame.depth, }
      if frame.anchor > 0 {
        self.anchors[frame.anchor] = cost
      }
      self.finish_node(cost)
    }
    _ => ()
  }
}

///|
fn YamlGuard::check_node(
  _self : YamlGuard,
  tag : @yaml.Tag?,
) -> Unit raise InvalidWorkflow {
  guard tag is None else {
    raise InvalidWorkflow("YAML explicit tags are not supported")
  }
}

///|
fn YamlGuard::charge(
  self : YamlGuard,
  cost : YamlCost,
) -> Unit raise InvalidWorkflow {
  self.nodes += cost.nodes
  self.bytes += cost.bytes
  guard self.nodes <= 8192 else {
    raise InvalidWorkflow("YAML exceeds 8192 nodes")
  }
  guard self.bytes <= 1048576 else {
    raise InvalidWorkflow("expanded YAML exceeds 1 MiB")
  }
  guard self.frames.length() + cost.depth <= 32 else {
    raise InvalidWorkflow("YAML nesting exceeds 32 levels")
  }
}

///|
fn YamlGuard::finish_node(self : YamlGuard, cost : YamlCost) -> Unit {
  if self.frames.last() is Some(frame) {
    frame.nodes += cost.nodes
    frame.bytes += cost.bytes
    frame.depth = Int32::max(frame.depth, cost.depth + 1)
    if frame.mapping {
      frame.key = !frame.key
    }
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
  let guard_ : YamlGuard = {
    frames: [],
    anchors: Map([]),
    documents: 0,
    nodes: 0,
    bytes: 0,
  }
  // Charge alias expansion before the loader constructs a shared tree. Only
  // completed anchors are visible, so cyclic references never reach the loader.
  @yaml.Parser(source).load(guard_, true) catch {
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
