///|
// The download credential enters this process through stdin, never argv, the
// workflow environment, or a URL. Redirects are limited to GitHub's codeload
// endpoint for this repository; the Authorization header is not forwarded.
let github_dependency_program : String =
  #|const fs = require('node:fs');
  #|(async () => {
  #| const x = JSON.parse(fs.readFileSync(0,'utf8'));
  #| if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(x.repository) || typeof x.ref !== 'string' || x.ref.length>200) throw Error();
  #| const base = 'https://api.github.com/repos/'+x.repository;
  #| const headers = {Authorization:'Bearer '+x.credential,Accept:'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'MoonHub-dependency-service'};
  #| const bounded = async (res,max) => { if (!res.ok || !res.body) throw Error(); let size=0; const chunks=[]; for await(const chunk of res.body) {size+=chunk.length;if(size>max)throw Error();chunks.push(chunk);} return Buffer.concat(chunks); };
  #| if (!x.archive) {
  #|   const res = await fetch(base+'/commits/'+encodeURIComponent(x.ref),{headers,redirect:'error',signal:AbortSignal.timeout(30000)});
  #|   const value = JSON.parse((await bounded(res,1048576)).toString());
  #|   if (!/^[a-f0-9]{40}$/.test(value.sha)) throw Error(); process.stdout.write(value.sha); return;
  #| }
  #| if (!/^[a-f0-9]{40}$/.test(x.ref)) throw Error();
  #| const res = await fetch(base+'/tarball/'+x.ref,{headers,redirect:'manual',signal:AbortSignal.timeout(30000)});
  #| if (res.status!==302) throw Error();
  #| const url = new URL(res.headers.get('location'));
  #| if (url.protocol!=='https:' || url.hostname!=='codeload.github.com' || url.port || url.username || url.password || !url.pathname.toLowerCase().startsWith('/'+x.repository.toLowerCase()+'/')) throw Error();
  #| const archive = await fetch(url,{redirect:'error',signal:AbortSignal.timeout(30000)});
  #| process.stdout.write(await bounded(archive,67108864));
  #|})().catch(()=>{process.stderr.write('Private action download failed');process.exitCode=1;});

///|
async fn github_dependency(
  repository : String,
  reference : String,
  credential : String,
  archive : Bool,
) -> Bytes {
  @async.with_timeout(65000, () => {
    @async.with_task_group(group => {
      let (input, writer) = @process.write_to_process()
      defer writer.close()
      group.spawn_bg(() => {
        writer.write(
          (
            {
              "repository": repository,
              "ref": reference,
              "credential": credential,
              "archive": archive,
            } : Json).stringify(),
        )
        writer.close()
      })
      let (reader, output) = @process.read_from_process()
      defer reader.close()
      let child = @process.spawn(
        group,
        "node",
        ["-e", github_dependency_program],
        stdin=input,
        stdout=output,
        stderr=@process.redirect_to_file("/dev/null"),
        inherit_env=false,
        extra_env={ "PATH": "/usr/bin:/bin:/usr/local/bin" },
      )
      let bytes : Array[Byte] = []
      while reader.read_some(max_len=8192) is Some(chunk) {
        guard bytes.length() + chunk.length() <= 67108864 else {
          raise @domain.BadRequest(
            message="private action archive exceeds 64 MiB",
          )
        }
        bytes.push_iter(chunk.iter())
      }
      guard child.wait() == 0 else {
        raise @domain.BadRequest(
          message="private action download failed; verify the repository grant and GitHub Contents read credential",
        )
      }
      Bytes::from_array(bytes)
    })
  })
}

///|
pub async fn Coordinator::resolve_private_action(
  self : Coordinator,
  token : String,
  target : String,
  reference : String,
  download~ : async (String, String, String, Bool) -> Bytes = github_dependency,
) -> String? {
  let granted = self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        let row = self.dependency_attempt(tx, token)
        tx.query_opt(
          "SELECT id FROM pipeline_dependency_grant WHERE repository_id=? AND kind='github' AND target=?",
          params=[row.repository_id, target],
        )
        is Some(_)
      },
      immediate=true,
    )
  })
  if !granted {
    return None
  }
  let scope = self.dependency_scope(token, "github", target, reference)
  if !scope.2.is_empty() {
    return Some(scope.2)
  }
  let sha = @utf8.decode(download(target, reference, scope.3.unwrap(), false))
  Some(self.pin_dependency(token, "github", target, reference, scope, sha))
}

///|
pub async fn Coordinator::private_action_archive(
  self : Coordinator,
  token : String,
  target : String,
  reference : String,
  download~ : async (String, String, String, Bool) -> Bytes = github_dependency,
) -> Bytes {
  let scope = self.dependency_scope(token, "github", target, reference)
  guard !scope.2.is_empty() else {
    raise @domain.BadRequest(
      message="resolve the private action before downloading",
    )
  }
  let bytes = download(target, scope.2, scope.3.unwrap(), true)
  guard bytes.length() <= 67108864 else {
    raise @domain.BadRequest(message="private action archive exceeds 64 MiB")
  }
  ignore(
    self.pin_dependency(token, "github", target, reference, scope, scope.2),
  )
  bytes
}
