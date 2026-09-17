///|
pub fn merge_status(mr : @collaboration.MergeRequest) -> String {
  if mr.status == "merged" {
    "Merged"
  } else if mr.status == "closed" {
    "Closed"
  } else if mr.job_status == "pending" || mr.job_status == "running" {
    "Merging"
  } else if mr.draft {
    "Draft"
  } else {
    "Open"
  }
}
