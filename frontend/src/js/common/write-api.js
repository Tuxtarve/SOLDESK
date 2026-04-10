const WRITE_API_BASE = '/api/write';

function resolveWriteTarget(path) {
  const rel = `${WRITE_API_BASE}${path}`;
  const runtime = window.APP_RUNTIME;
  if (runtime && typeof runtime.resolveTicketingApiUrl === 'function') {
    return runtime.resolveTicketingApiUrl(rel);
  }
  return rel;
}

async function writeApi(path, method = 'POST', data = null, options = {}) {
  const runtime = window.APP_RUNTIME;
  if (runtime && typeof runtime.ensureTicketingEndpointsLoaded === 'function') {
    await runtime.ensureTicketingEndpointsLoaded();
  }
  const targetPath = resolveWriteTarget(path);

  if (runtime && typeof runtime.requestJson === 'function') {
    const result = await runtime.requestJson(targetPath, {
      ...(options || {}),
      method,
      body: data
    });
    const m = String(method || 'POST').toUpperCase();
    if (runtime && typeof runtime.notifyReadCacheRebuilt === 'function' && ['POST', 'PUT', 'PATCH', 'DELETE'].includes(m)) {
      runtime.notifyReadCacheRebuilt();
    }
    return result;
  }

  const fetchOptions = {
    method,
    credentials: 'include',
    headers: {
      'Content-Type': 'application/json'
    }
  };

  if (data !== null) {
    fetchOptions.body = JSON.stringify(data);
  }

  const response = await fetch(targetPath, fetchOptions);

  if (!response.ok) {
    let errorMessage = `WRITE API 오류: ${response.status}`;
    const httpError = new Error(errorMessage);
    httpError.status = response.status;
    httpError.data = null;

    try {
      const errorData = await response.json();
      httpError.data = errorData;
      if (errorData && errorData.message) {
        errorMessage = errorData.message;
      }
    } catch (error) {
      console.error(error);
    }

    httpError.message = errorMessage;
    throw httpError;
  }

  const result = await response.json();
  const m = String(method || 'POST').toUpperCase();
  if (runtime && typeof runtime.notifyReadCacheRebuilt === 'function' && ['POST', 'PUT', 'PATCH', 'DELETE'].includes(m)) {
    runtime.notifyReadCacheRebuilt();
  }
  return result;
}
