///|
priv suberror PageTransport

///|
fn page_subscription(emit : @rabbita.Emit[(@spa.Page, Int32)]) -> @sub.Sub {
  @sub.custom_sub("moonhub:page", Global, PageTransport, (_, scheduler) => {
    let mut generation = 0
    let listener : @dom.Listener = event => {
      if event.to_custom_event() is Some(event) {
        let json : String = event.get_detail().cast()
        let page : @spa.Page = @json.from_json(@json.parse(json)) catch {
          _ => return
        }
        generation += 1
        scheduler.add(emit((page, generation)))
      }
    }
    let target = @dom.document().as_event_target()
    target.add_event_listener("moonhub:page", listener)
    Some({
      unload: _ => target.remove_event_listener("moonhub:page", listener),
      update_tagger: _ => (),
    })
  })
}

///|
pub fn start(json : String) -> Unit raise {
  let initial : @spa.Page = @json.from_json(@json.parse(json))
  let app = @rabbita.new(() => {
    let (page, _) = @rabbita.create_state(
      (initial, 0),
      update=(_, next, _) => {
        (next, @cmd.custom_cmd(_ => rendered(), kind=AfterRender))
      },
      subscriptions=(_, emit) => page_subscription(emit),
    )
    page.map(value => {
      let (page, generation) = value
      @spa.document(page, generation)
    })
  })
  app.hydrate()
}

///|
extern "js" fn rendered() -> Unit =
  #|() => document.dispatchEvent(new Event("moonhub:rendered"))
