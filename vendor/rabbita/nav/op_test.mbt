///|
test "navigation commands have structural debug output" {
  debug_inspect(@nav.back(), content="NavBack")
  debug_inspect(@nav.push_url("/profile"), content="NavPushUrl(\"/profile\")")
  debug_inspect(
    @nav.scroll_to_pos(10.25, 20.75, behavior=Smooth),
    content="NavScrollToPos(10.25, 20.75, Smooth)",
  )
  debug_inspect(
    @nav.scroll_by_pos(-0.5, 1.125),
    content="NavScrollByPos(-0.5, 1.125, Auto)",
  )
}
