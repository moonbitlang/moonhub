///|
#derive(Debug, ToJson, FromJson)
pub(all) struct ConfigField {
  name : String
  title : String
  kind : String
  required : Bool
  choices : Array[String]
  minimum : Int32
  maximum : Int32
  help : String
}

///|
pub fn validate_config(
  schema : Array[ConfigField],
  values : Map[String, String],
) -> String? {
  if schema.length() > 24 || values.length() > 24 {
    return Some("Too many configuration fields.")
  }
  let names : Map[String, Bool] = Map([])
  for field in schema {
    if field.name.is_empty() ||
      field.name.length() > 64 ||
      !field.name
      .iter()
      .all(c => c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '_') ||
      names.contains(field.name) ||
      field.title.is_empty() ||
      field.title.length() > 100 ||
      field.help.length() > 600 ||
      field.choices.length() > 32 ||
      field.choices.any(value => value.length() > 256) ||
      !["text", "integer", "choice"].contains(field.kind) ||
      field.minimum < 0 ||
      field.maximum < field.minimum {
      return Some("Invalid configuration schema.")
    }
    names[field.name] = true
    let value = values.get(field.name).unwrap_or("")
    if value.length() > 1024 ||
      value.iter().any(c => c.to_int() < 32 || c.to_int() == 127) {
      return Some(
        "Configuration values must be single-line text up to 1024 characters.",
      )
    }
    if value.is_empty() {
      if field.required {
        return Some(field.title + " is required.")
      }
      continue
    }
    if field.kind == "integer" {
      guard parse_decimal(value) is Some(number) &&
        number >= field.minimum.to_int64() &&
        number <= field.maximum.to_int64() else {
        return Some(field.title + " is outside its allowed range.")
      }
    }
    if field.kind == "choice" && !field.choices.contains(value) {
      return Some(field.title + " is not an allowed choice.")
    }
  }
  for key, _ in values {
    if !names.contains(key) {
      return Some("Unknown configuration field.")
    }
  }
  None
}

///|
#derive(ToJson, FromJson)
pub(all) struct RegisterProviderRequest {
  version : Int32
  name : String
  mode : String
  provider_token : String
  schema : Array[ConfigField]
  defaults : Map[String, String]
}

///|
#derive(ToJson, FromJson)
pub(all) struct ProviderSyncRequest {
  version : Int32
  controller_id : String
  observed_revision : String
  applied_revision : String
  status : String
  schema : Array[ConfigField]?
  defaults : Map[String, String]?
}

///|
#derive(ToJson, FromJson)
pub(all) struct WorkerRegistration {
  version : Int32
  key : String
  token : String
}

///|
#derive(ToJson, FromJson)
pub(all) struct WorkerSyncRequest {
  version : Int32
  state : String
  applied_revision : String
}

///|
#derive(Debug, ToJson, FromJson)
pub(all) struct WorkerView {
  id : String
  key : String
  state : String
  draining : Bool
  applied_revision : String
  last_seen_ms : String
  idle_since_ms : String
  active_attempts : Int32
}

///|
#derive(Debug, ToJson, FromJson)
pub(all) struct ProviderSnapshot {
  version : Int32
  id : String
  mode : String
  paused : Bool
  config_revision : String
  schema : Array[ConfigField]
  config : Map[String, String]
  queued_jobs : Int32
  workers : Array[WorkerView]
}

///|
#derive(Debug, ToJson, FromJson)
pub(all) struct WorkerSnapshot {
  version : Int32
  provider_id : String
  worker_id : String
  paused : Bool
  draining : Bool
  config_revision : String
  config : Map[String, String]
}

///|
pub extend ConfigField with @debug.Debug::{to_repr}

///|
pub extend ConfigField with ToJson::{to_json}

///|
pub extend ConfigField with @json.FromJson::{from_json}

///|
pub extend RegisterProviderRequest with ToJson::{to_json}

///|
pub extend RegisterProviderRequest with @json.FromJson::{from_json}

///|
pub extend ProviderSyncRequest with ToJson::{to_json}

///|
pub extend ProviderSyncRequest with @json.FromJson::{from_json}

///|
pub extend WorkerRegistration with ToJson::{to_json}

///|
pub extend WorkerRegistration with @json.FromJson::{from_json}

///|
pub extend WorkerSyncRequest with ToJson::{to_json}

///|
pub extend WorkerSyncRequest with @json.FromJson::{from_json}

///|
pub extend WorkerView with @debug.Debug::{to_repr}

///|
pub extend WorkerView with ToJson::{to_json}

///|
pub extend WorkerView with @json.FromJson::{from_json}

///|
pub extend ProviderSnapshot with @debug.Debug::{to_repr}

///|
pub extend ProviderSnapshot with ToJson::{to_json}

///|
pub extend ProviderSnapshot with @json.FromJson::{from_json}

///|
pub extend WorkerSnapshot with @debug.Debug::{to_repr}

///|
pub extend WorkerSnapshot with ToJson::{to_json}

///|
pub extend WorkerSnapshot with @json.FromJson::{from_json}

///|
pub fn standby_counts(
  workers : Array[WorkerView],
  revision : String,
  now_ms : Int64,
) -> (Int32, Int32) {
  let mut ready = 0
  let mut preparing = 0
  for worker in workers {
    let seen = parse_decimal(worker.last_seen_ms).unwrap_or(0L)
    if worker.draining ||
      worker.active_attempts > 0 ||
      seen <= 0L ||
      now_ms - seen >= 180000L {
      continue
    }
    if worker.state == "ready" && worker.applied_revision == revision {
      ready += 1
    } else if worker.state == "starting" || worker.state == "ready" {
      preparing += 1
    }
  }
  (ready, preparing)
}
