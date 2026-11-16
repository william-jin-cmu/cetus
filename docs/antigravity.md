# Antigravity CLI

Cetus 0.5.9 supports Antigravity through the CLI's native Agent Client Protocol
(`agy acp`). Install the CLI using the [official instructions](https://antigravity.google/docs/getting-started),
then sign in with `agy acp --login`. Restart Cetus after installing the CLI so
it picks up the updated shell PATH. Select **Antigravity** in the runtime picker;
the runtime can be enabled or disabled in Settings → Runtimes.

Cetus uses Antigravity's native `configOptions` for separate model and reasoning
selectors. Each model offers only its supported thinking levels. Existing 0.5.9
combined selections are resolved against the CLI catalog when possible. The
icon is the original SVG from https://antigravity.google/favicon.svg. Streaming replies,
tool approval cards, attachments, cancellation, and continued conversations use
the shared ACP bridge. Threads and scheduled jobs accept `antigravity` as the
runtime/backend id.

## Google Cloud and API-key authentication

The default path reuses the CLI's own login. For noninteractive authentication,
Cetus also honors `auth.type` in `~/.gemini/antigravity-cli/settings.json`:
`gemini-api-key` or `agent-platform`. It sends the corresponding ACP authenticate
request before opening or restoring a session. For example:

```json
{
  "auth": { "type": "agent-platform" },
  "gcp": { "project": "YOUR_PROJECT_ID", "location": "global" }
}
```

Child processes inherit your login-shell environment. To scope credentials to
Antigravity alone, optionally put a string-to-string environment map in
`~/.config/cetus/antigravity/env.json`. Cetus reads only `GEMINI_API_KEY`,
`GOOGLE_API_KEY`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`,
`GOOGLE_APPLICATION_CREDENTIALS`, and `GOOGLE_GEMINI_BASE_URL` from this file.
These values are applied to the Antigravity session and model-catalog probe,
not to other runtimes. Restrict the file to your user (`chmod 600`) and do not
commit credentials to a repository.

Use credentials appropriate for the selected API. A standard unrestricted
Gemini Developer API key does not by itself configure Vertex AI authentication.
Google Cloud credit eligibility depends on the billing account and credit
terms; choosing a project does not guarantee that credits cover its requests.
See [Antigravity authentication](https://antigravity.google/docs/install).
