///|
fn render_inline_composer(
  base : String,
  csrf : String,
  version : String,
  commit : String,
  form : Map[String, String],
  error : String?,
) -> @moonback.Html {
  Html(b => {
    b <+ "<details id=\"inline-composer\" class=\"inline-composer\""
    if error is Some(_) {
      b <+ " open"
    }
    b <+ "><summary>Enter a code location manually</summary>"
    if error is Some(message) {
      b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
    }
    b <+
      "<p class=\"muted inline-manual-help\">Select line numbers in the diff, or enter a path and a range of 1–100 displayed lines. Select one side and one hunk.</p><form class=\"form-stack mr-form\" data-inline-form method=\"post\" action=\"\{base}/inline-comment\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{version}\"><input type=\"hidden\" name=\"commit\" value=\"\{commit}\"><div class=\"inline-location-fields\"><label class=\"field\"><span>File path</span><input name=\"path\" value=\"\{form.get("path").unwrap_or("")}\" required maxlength=\"4096\"></label><div class=\"mr-actions\"><label class=\"field\"><span>Side</span><select name=\"side\"><option value=\"new\">New</option><option value=\"old\" \{if form.get("side") == Some("old") { "selected" } else { "" }}>Old</option></select></label><label class=\"field\"><span>Start line</span><input name=\"start_line\" value=\"\{form.get("start_line").unwrap_or("")}\" type=\"number\" min=\"1\" max=\"1000000000\" required></label><label class=\"field\"><span>End line</span><input name=\"end_line\" value=\"\{form.get("end_line").unwrap_or("")}\" type=\"number\" min=\"1\" max=\"1000000000\" required></label></div></div><label class=\"field\"><span>Comment</span><textarea name=\"body\" required maxlength=\"20000\" rows=\"4\">\{form.get("body").unwrap_or("")}</textarea></label><div class=\"inline-editor-actions\"><button type=\"submit\">Start discussion</button><button type=\"button\" class=\"secondary-button\" data-inline-cancel hidden>Cancel</button><button type=\"button\" class=\"text-button\" data-inline-discard hidden>Discard draft</button></div></form></details>"
  })
}
