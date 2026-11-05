///|
pub let protocol_version : String = "moonhub-diff/1"

///|
pub let engine_version : String = "moondiff/0.1.3"

///|
pub let source_limit : Int32 = 1048576

///|
pub let line_limit : Int32 = 20000

///|
pub let request_limit : Int32 = 16777216

///|
pub let result_limit : Int32 = 2097152

///|
pub let stderr_limit : Int32 = 65536

///|
pub let context_lines : Int32 = 3

///|
pub let graph_limit : UInt32 = 3000000U

///|
pub let queue_limit : Int32 = 16

///|
pub let queue_wait_ms : Int32 = 2000

///|
pub let cache_limit : Int64 = 33554432L

///|
#derive(ToJson, FromJson, Eq)
pub(all) struct Options {
  mode : String
  ignore_comments : Bool
  ignore_tests : Bool
}

///|
pub fn Options::new(
  mode~ : String = "lexical",
  ignore_comments~ : Bool = true,
  ignore_tests~ : Bool = true,
) -> Options {
  { mode, ignore_comments, ignore_tests, }
}

///|
#derive(ToJson, FromJson)
pub(all) struct Request {
  protocol : String
  old_path : String
  new_path : String
  old_source : String?
  new_source : String?
  options : Options
}

///|
#derive(ToJson, FromJson)
pub(all) struct Segment {
  kind : String
  text : String
}

///|
#derive(ToJson, FromJson)
pub(all) struct Line {
  number : Int32
  segments : Array[Segment]
  intraline : Bool
}

///|
#derive(ToJson, FromJson)
pub(all) struct Row {
  kind : String
  old : Line?
  new : Line?
}

///|
#derive(ToJson, FromJson)
pub(all) struct Hunk {
  id : String
  rows : Array[Row]
}

///|
#derive(ToJson, FromJson)
pub(all) struct Range {
  start : Int32
  length : Int32
}

///|
#derive(ToJson, FromJson)
pub(all) struct Section {
  id : String
  kind : String
  old : Range?
  new : Range?
  old_context : String?
  new_context : String?
  hunks : Array[Hunk]
  fallbacks : Array[String]
}

///|
#derive(ToJson, FromJson)
pub(all) struct Document {
  protocol : String
  engine : String
  options : Options
  status : String
  kind : String
  ignore_reason : String?
  reordered : Bool
  old_order : Array[Int32]
  new_order : Array[Int32]
  old_eol : String
  new_eol : String
  old_final_newline : Bool?
  new_final_newline : Bool?
  sections : Array[Section]
}

///|
#derive(ToJson, FromJson)
pub(all) struct Response {
  protocol : String
  document : Document?
  error : String?
}

///|
pub extend Options with ToJson::{to_json}

///|
pub extend Options with @json.FromJson::{from_json}

///|
pub extend Request with ToJson::{to_json}

///|
pub extend Request with @json.FromJson::{from_json}

///|
pub extend Segment with ToJson::{to_json}

///|
pub extend Segment with @json.FromJson::{from_json}

///|
pub extend Line with ToJson::{to_json}

///|
pub extend Line with @json.FromJson::{from_json}

///|
pub extend Row with ToJson::{to_json}

///|
pub extend Row with @json.FromJson::{from_json}

///|
pub extend Hunk with ToJson::{to_json}

///|
pub extend Hunk with @json.FromJson::{from_json}

///|
pub extend Range with ToJson::{to_json}

///|
pub extend Range with @json.FromJson::{from_json}

///|
pub extend Section with ToJson::{to_json}

///|
pub extend Section with @json.FromJson::{from_json}

///|
pub extend Document with ToJson::{to_json}

///|
pub extend Document with @json.FromJson::{from_json}

///|
pub extend Response with ToJson::{to_json}

///|
pub extend Response with @json.FromJson::{from_json}

///|
pub extend Options with Eq::{equal, not_equal}
