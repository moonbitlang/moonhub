// Workflow/job/step mapping is adapted from mizchi/actrun v0.30.1.
// See THIRD_PARTY.md for provenance and the changes to its contract.

///|
pub suberror InvalidWorkflow {
  InvalidWorkflow(String)
} derive(Debug)

///|
pub let max_source_bytes : Int32 = 65536

///|
pub let format_version : Int32 = 1

///|
pub struct Workflow {
  name : String
  jobs : Array[Job]
} derive(Debug, ToJson, FromJson)

///|
pub struct Job {
  id : String
  name : String
  needs : Array[String]
  runs_on : Array[String]
  timeout_minutes : Int32
  steps : Array[Step]
} derive(Debug, ToJson, FromJson)

///|
pub struct Step {
  id : String
  name : String
  run : String
  shell : String?
  working_directory : String
  env : Map[String, String]
  timeout_minutes : Int32?
} derive(Debug, ToJson, FromJson)

///|
priv struct RunDefaults {
  shell : String?
  working_directory : String?
}
