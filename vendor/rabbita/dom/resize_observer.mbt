///|
/// https://developer.mozilla.org/en-US/docs/Web/API/ResizeObserver
#cfg(target="js")
#external
type ResizeObserver

///|
/// https://developer.mozilla.org/en-US/docs/Web/API/ResizeObserverEntry
#cfg(target="js")
#external
type ResizeObserverEntry

///|
/// https://developer.mozilla.org/en-US/docs/Web/API/ResizeObserver/ResizeObserver
#cfg(target="js")
pub fn ResizeObserver::new(
  callback : (FixedArray[ResizeObserverEntry], ResizeObserver) -> Unit,
) -> Self {
  ffi_resize_observer_new(callback)
}

///|
#cfg(target="js")
extern "js" fn ffi_resize_observer_new(
  callback : (FixedArray[ResizeObserverEntry], ResizeObserver) -> Unit,
) -> ResizeObserver = "(callback) => new ResizeObserver(callback)"

///|
/// https://developer.mozilla.org/en-US/docs/Web/API/ResizeObserver/observe
#cfg(target="js")
pub extern "js" fn ResizeObserver::observe(
  self : Self,
  target : Element,
) -> Unit = "(self, target) => self.observe(target)"

///|
/// https://developer.mozilla.org/en-US/docs/Web/API/ResizeObserver/unobserve
#cfg(target="js")
pub extern "js" fn ResizeObserver::unobserve(
  self : Self,
  target : Element,
) -> Unit = "(self, target) => self.unobserve(target)"

///|
/// https://developer.mozilla.org/en-US/docs/Web/API/ResizeObserver/disconnect
#cfg(target="js")
pub extern "js" fn ResizeObserver::disconnect(self : Self) -> Unit = "(self) => self.disconnect()"
