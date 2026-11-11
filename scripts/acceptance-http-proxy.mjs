import http from 'node:http';

// A runner cancels its heartbeat when execution completes. Propagate downstream
// cancellation without mistaking the resulting upstream reset for a test error.
export function forwardAcceptanceRequest(req, res, backend, {body, onError}) {
  let cancelled = false, failed = false;
  const fail = error => {
    if (!cancelled && !failed) {failed = true; onError(error);}
    res.destroy();
  };
  const upstream = http.request({
    hostname: backend.hostname, port: backend.port, path: req.url,
    method: req.method, headers: {...req.headers, host: backend.host}, agent: false,
  }, response => {
    if (cancelled) {response.destroy(); return;}
    response.on('error', fail);
    res.writeHead(response.statusCode, response.headers);
    response.pipe(res);
  });
  upstream.on('error', fail);
  const cancel = () => {cancelled = true; upstream.destroy();};
  req.on('aborted', cancel);
  res.on('close', () => {if (!res.writableFinished) cancel();});
  if (body) upstream.end(body); else req.pipe(upstream);
}
