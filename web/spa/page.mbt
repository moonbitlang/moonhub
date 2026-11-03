///|
/// The migration boundary: only already-escaped, server-authorized presentation
/// enters this tree. Business services and HTTP objects never enter the browser.
#derive(Eq, Debug, ToJson, FromJson)
pub(all) enum Node {
  Element(String, Array[(String, String)], Array[Node])
  Text(String)
}

///|
#derive(Eq, Debug, ToJson, FromJson)
pub(all) struct Page {
  head : Array[Node]
  body : Array[Node]
}

///|
fn Node::view(self : Node) -> @html.Html {
  match self {
    Text(text) => @html.text(text)
    Element(tag, attributes, children) => {
      let attrs = @html.Attrs::build()
      for (name, value) in attributes {
        attrs.attribute(name, value) |> ignore
      }
      @html.node(tag, attrs, children.map(child => child.view()))
    }
  }
}

///|
/// Hydration adopts the initial tree; navigation starts a fresh page lifetime.
pub fn document(page : Page, generation : Int32) -> @html.Html {
  @html.html(attrs=@html.Attrs::build().lang("en"), [
    @html.head(page.head.map(node => node.view())),
    @html.body(
      Map::from_array([
        (
          generation.to_string(),
          @html.div(
            id="moonhub-page",
            attrs=@html.Attrs::build().style_attr("display:contents"),
            page.body.map(node => node.view()),
          ),
        ),
      ]),
    ),
  ])
}

///|
/// Prevent raw-text script termination when embedding the initial page state.
pub fn bootstrap_json(page : Page) -> String {
  page
  .to_json()
  .stringify()
  .replace_all(old="<", new="\\u003c")
  .replace_all(old=">", new="\\u003e")
  .replace_all(old="&", new="\\u0026")
}

///|
pub extend Node with Eq::{equal, not_equal}

///|
pub extend Node with ToJson::{to_json}

///|
pub extend Node with @json.FromJson::{from_json}

///|
pub extend Page with Eq::{equal, not_equal}

///|
pub extend Page with ToJson::{to_json}

///|
pub extend Page with @json.FromJson::{from_json}

///|
pub extend Node with @debug.Debug::{to_repr}

///|
pub extend Page with @debug.Debug::{to_repr}
