///|
pub let single_job_workflow : String =
  #|name: Protocol fixture
  #|on: workflow_dispatch
  #|jobs:
  #|  build:
  #|    runs-on: [self-hosted, linux]
  #|    timeout-minutes: 1
  #|    steps:
  #|      - id: check
  #|        run: echo fixture

///|
pub async fn workflow_commit(
  git_dir : String,
  source : String,
  mode? : String = "100644",
) -> String {
  let blob = @gitops.merge_git(
      git_dir,
      ["hash-object", "-w", "--stdin"],
      input=source,
    )
    .trim()
    .to_owned()
  let workflows = @gitops.merge_git(
      git_dir,
      ["mktree"],
      input="\{mode} blob \{blob}\tbuild.yml\n",
    )
    .trim()
    .to_owned()
  let github = @gitops.merge_git(
      git_dir,
      ["mktree"],
      input="040000 tree \{workflows}\tworkflows\n",
    )
    .trim()
    .to_owned()
  let tree = @gitops.merge_git(
      git_dir,
      ["mktree"],
      input="040000 tree \{github}\t.github\n",
    )
    .trim()
    .to_owned()
  let commit = @gitops.merge_git(git_dir, [
      "commit-tree", tree, "-m", "Workflow fixture",
    ])
    .trim()
    .to_owned()
  ignore(
    @gitops.merge_git(git_dir, ["update-ref", "refs/heads/pipeline", commit]),
  )
  commit
}
