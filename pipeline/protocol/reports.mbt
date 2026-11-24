///|
#derive(ToJson, FromJson, Debug, Eq)
pub(all) struct Annotation {
  severity : String
  message : String
  title : String
  file : String
  line : Int32
  end_line : Int32
  column : Int32
  end_column : Int32
}

///|
#derive(ToJson, FromJson, Debug, Eq)
pub(all) struct StepReport {
  step_id : String
  summary : String
  annotations : Array[Annotation]
}

///|
#derive(ToJson, FromJson, Debug, Eq)
pub(all) struct JobReport {
  revision : Int32
  entries : Array[StepReport]
  truncated : Bool
}

///|
#derive(ToJson, FromJson)
pub(all) struct ReportRequest {
  version : Int32
  execution_id : String
  report : JobReport
}
