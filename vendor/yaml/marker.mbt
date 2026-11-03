///|
#derive(Debug, Eq)
pub struct Marker {
  /// The index (in chars) in the input string.
  index : Int32
  /// The line (1-indexed).
  line : Int32
  /// The column (1-indexed).
  col : Int32
}
