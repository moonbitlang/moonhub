///|
async test "controlled GitHub downloader confines the raw credential and rejects foreign redirects" {
  for
    location in [
      "https://codeload.github.com/private/action/legacy.tar.gz/sha?token=signed",
      "https://foreign.example/private/action/archive", "https://codeload.github.com/private/other/archive",
      "https://codeload.github.com.evil.example/private/action/archive",
    ] {
    let allowed = location ==
      "https://codeload.github.com/private/action/legacy.tar.gz/sha?token=signed"
    let setup = (
      #|const assert = require('node:assert/strict');
      #|global.fetch = async (url, options) => {
      #| if (String(url).startsWith('https://api.github.com/')) {
      #|   assert.equal(String(url),'https://api.github.com/repos/private/action/tarball/'+'a'.repeat(40));
      #|   assert.equal(options.headers.Authorization,'Bearer server-only-credential');
      #|   assert.equal(options.redirect,'manual');
      #|   return new Response(null,{status:302,headers:{location:LOCATION}});
      #| }
      #| assert.equal(String(url),'https://codeload.github.com/private/action/legacy.tar.gz/sha?token=signed');
      #| assert.equal(options.headers,undefined);
      #| assert.equal(options.redirect,'error');
      #| return new Response('bounded-archive');
      #|};
    ).replace_all(old="LOCATION", new=Json(location).stringify())
    @async.with_task_group(group => {
      let (stdin, writer) = @process.write_to_process()
      defer writer.close()
      group.spawn_bg(() => {
        writer.write(
          (
            {
              "repository": "private/action",
              "ref": "a".repeat(40),
              "credential": "server-only-credential",
              "archive": true,
            } : Json).stringify(),
        )
        writer.close()
      })
      let (code, stdout, stderr) = @process.collect_output(
        "node",
        ["-e", setup + github_dependency_program],
        stdin~,
      )
      assert_eq(code, if allowed { 0 } else { 1 })
      assert_eq(stdout.text(), if allowed { "bounded-archive" } else { "" })
      assert_true(!stderr.text().contains("server-only-credential"))
    })
  }
}
