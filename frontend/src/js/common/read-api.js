const READ_API_BASE = '/api/read';

function resolveReadTarget(path) {
  const rel = `${READ_API_BASE}${path}`;
  const runtime = window.APP_RUNTIME;
  if (runtime && typeof runtime.resolveTicketingApiUrl === 'function') {
    return runtime.resolveTicketingApiUrl(rel);
  }
  return rel;
}

async function readApi(path, options = {}) {
  const runtime = window.APP_RUNTIME;
  if (runtime && typeof runtime.ensureTicketingEndpointsLoaded === 'function') {
    await runtime.ensureTicketingEndpointsLoaded();
  }
  const targetPath = resolveReadTarget(path);

  if (runtime && typeof runtime.getJson === 'function') {
    return runtime.getJson(targetPath, options);
  }

  const response = await fetch(targetPath, {
    method: 'GET',
    credentials: 'include',
    cache: options.cache || 'default'
  });

  if (!response.ok) {
    throw new Error(`READ API 오류: ${response.status}`);
  }

  return await response.json();
}
