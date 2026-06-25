/* API middleware: key-based authentication.
   Protects all /api/* routes. Configure REX_SECRET_API_KEY in the environment;
   rex-serve exposes it to Rex as secrets.api-key. */

api-key = headers.authorization
expected-key = secrets.api-key

unless expected-key do
  res.status = 503
  return { ok: false error: "api_key_not_configured" }
end

unless api-key do
  res.status = 401
  return { ok: false error: "missing_api_key" hint: "Add the configured key in the Authorization header" }
end

unless api-key == expected-key do
  res.status = 401
  return { ok: false error: "invalid_api_key" }
end

log.info("authenticated API request")
