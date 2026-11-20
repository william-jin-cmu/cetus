//! Unified usage & billing readout across every runtime and model provider the
//! user has enabled and configured in Cetus:
//!
//! - **Subscription quotas (`billing = "subscription"`)**:
//!   Claude Code (OAuth), Codex (ChatGPT OAuth), Antigravity (Google Code
//!   Assist OAuth when signed in with consumer/workspace quota).
//! - **Prepaid balances (`billing = "balance"`)**:
//!   Built-in DeepSeek (`pi`), DeepSeek Harness (`dsh`), and OpenRouter /
//!   DeepSeek custom providers — live account balance paired with local 1d/7d
//!   token & cache-hit telemetry. Identical DeepSeek keys share one HTTP fetch.
//! - **Metered / multi-provider (`billing = "metered"`)**:
//!   OpenCode (read directly from `~/.local/share/opencode/opencode.db`),
//!   Antigravity on Vertex AI / Gemini API key, API-key-backed Claude/Codex/
//!   Grok/Kimi, and custom OpenAI-compatible providers (with optional per-1M
//!   token unit prices). Zero-cost gateway runs surface tokens & cache hit
//!   rates instead of a misleading `$0.00`.

use std::collections::HashMap;
use std::io::BufRead;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, UNIX_EPOCH};

use host::State;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::store::usage::{ModelUsageRollup, UsageRollup};
use crate::store::Store;
use crate::AppState;

const HTTP_TIMEOUT: Duration = Duration::from_secs(12);
/// A snapshot younger than this is served as-is unless the caller forces it or
/// a local turn records fresh usage.
const CACHE_TTL: Duration = Duration::from_secs(120);
const CLAUDE_KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
const CLAUDE_OAUTH_BETA: &str = "oauth-2025-04-20";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    pub id: String,
    pub label: String,
    /// 0–100, None when the vendor omitted it.
    pub used_pct: Option<f64>,
    /// ISO-8601.
    pub resets_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageDetail {
    pub label: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageBalance {
    pub amount: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSpend {
    pub today_tokens: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub today_cost_usd: Option<f64>,
    pub week_tokens: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub week_cost_usd: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_hit_pct: Option<u8>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderUsage {
    /// Stable unique id ("claude-code", "codex", "opencode", "pi", "dsh",
    /// "antigravity", "grok", "kimi", "custom-<slug>").
    pub id: String,
    /// Kept alongside `id` so Cetus Remote clients decoding the legacy
    /// `provider` key ("claude" | "codex" | …) stay compatible.
    pub provider: String,
    /// Brand icon selector for the frontend:
    /// "claude" | "codex" | "opencode" | "cetus" | "dsh" | "antigravity" |
    /// "grok" | "kimi" | "custom".
    pub kind: &'static str,
    pub name: String,
    /// "subscription" | "balance" | "metered".
    pub billing: &'static str,
    /// "ok" | "signedOut" | "expired" | "error".
    pub status: &'static str,
    pub plan: Option<String>,
    pub account: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub balance: Option<UsageBalance>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spend: Option<UsageSpend>,
    pub windows: Vec<UsageWindow>,
    pub details: Vec<UsageDetail>,
    pub error: Option<String>,
}

impl ProviderUsage {
    fn new(
        id: impl Into<String>,
        kind: &'static str,
        name: impl Into<String>,
        billing: &'static str,
        status: &'static str,
    ) -> Self {
        let id = id.into();
        let provider = if id == "claude-code" {
            "claude".to_string()
        } else {
            id.clone()
        };
        Self {
            id,
            provider,
            kind,
            name: name.into(),
            billing,
            status,
            plan: None,
            account: None,
            balance: None,
            spend: None,
            windows: Vec::new(),
            details: Vec::new(),
            error: None,
        }
    }

    fn failed(
        id: impl Into<String>,
        kind: &'static str,
        name: impl Into<String>,
        billing: &'static str,
        error: String,
    ) -> Self {
        Self {
            error: Some(error),
            ..Self::new(id, kind, name, billing, "error")
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSnapshot {
    pub providers: Vec<ProviderUsage>,
    /// Unix ms.
    pub fetched_at: i64,
}

struct Cache {
    at: Instant,
    snapshot: UsageSnapshot,
}

static CACHE: Mutex<Option<Cache>> = Mutex::new(None);
/// Claude's usage endpoint answers 429 with a Retry-After in the tens of
/// minutes; until it passes, report that instead of calling again.
static CLAUDE_LIMITED_UNTIL: Mutex<Option<Instant>> = Mutex::new(None);

/// Clear the cached snapshot after a turn records new local usage so opening
/// the popover immediately reflects the turn that just ran.
pub fn invalidate_cache() {
    *CACHE.lock().unwrap() = None;
}

#[host::command]
pub async fn provider_usage(
    state: State<'_, AppState>,
    force: Option<bool>,
) -> Result<UsageSnapshot, String> {
    if !force.unwrap_or(false) {
        if let Some(c) = CACHE.lock().unwrap().as_ref() {
            if c.at.elapsed() < CACHE_TTL {
                return Ok(c.snapshot.clone());
            }
        }
    }

    let client = reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .build()
        .map_err(|e| e.to_string())?;

    let cli_settings = crate::cli_backend::load_settings(&state.store);
    let custom_providers = crate::custom_models::load(&state.store);

    // Deduplicate DeepSeek balance calls when Cetus (`pi`) and `dsh` (or a
    // custom DeepSeek provider) share the same API key against official DeepSeek.
    let pi_ds_key = resolve_pi_deepseek_key();
    let pi_ds_official = crate::provider::deepseek_base_url(&state.store)
        .is_none_or(|u| u.contains("api.deepseek.com"));
    let dsh_ds_key = if cli_settings.dsh_enabled {
        resolve_dsh_deepseek_key()
    } else {
        None
    };

    let mut ds_keys_to_fetch: Vec<String> = Vec::new();
    if let Some(k) = pi_ds_key.as_ref().filter(|_| pi_ds_official) {
        ds_keys_to_fetch.push(k.clone());
    }
    if let Some(k) = dsh_ds_key.as_ref() {
        if !ds_keys_to_fetch.contains(k) {
            ds_keys_to_fetch.push(k.clone());
        }
    }

    // Kick off network-bound probes concurrently.
    let claude_fut = async {
        if cli_settings.claude_code_enabled {
            Some(claude_usage(&client, &state.store).await)
        } else {
            None
        }
    };
    let codex_fut = async {
        if cli_settings.codex_enabled {
            Some(codex_usage(&client, &state.store).await)
        } else {
            None
        }
    };
    let agy_fut = async {
        if cli_settings.antigravity_enabled {
            antigravity_usage(&client, &state.store).await
        } else {
            None
        }
    };
    let ds_balances_fut = async {
        let mut out: HashMap<String, Result<UsageBalance, String>> = HashMap::new();
        for key in &ds_keys_to_fetch {
            out.insert(
                key.clone(),
                fetch_deepseek_balance(&client, "https://api.deepseek.com", key).await,
            );
        }
        out
    };
    let custom_fut = collect_custom_providers(&client, &state.store, &custom_providers);

    let (claude_card, codex_card, agy_card, ds_balances, custom_cards) =
        tokio::join!(claude_fut, codex_fut, agy_fut, ds_balances_fut, custom_fut);

    let shared_ds_key = match (&pi_ds_key, &dsh_ds_key) {
        (Some(a), Some(b)) if pi_ds_official && a == b => Some(a.as_str()),
        _ => None,
    };

    let mut by_runtime: HashMap<String, ProviderUsage> = HashMap::new();

    if let Some(card) = pi_usage(
        &state.store,
        pi_ds_key.as_deref(),
        pi_ds_official,
        &ds_balances,
    ) {
        by_runtime.insert("pi".into(), card);
    }
    if let Some(card) = claude_card {
        by_runtime.insert("claude-code".into(), card);
    }
    if let Some(card) = codex_card {
        by_runtime.insert("codex".into(), card);
    }
    if cli_settings.opencode_enabled {
        if let Some(card) = opencode_usage(&state.store) {
            by_runtime.insert("opencode".into(), card);
        }
    }
    if let Some(card) = agy_card {
        by_runtime.insert("antigravity".into(), card);
    }
    if cli_settings.dsh_enabled {
        if let Some(card) = dsh_usage(
            &state.store,
            dsh_ds_key.as_deref(),
            shared_ds_key.is_some(),
            &ds_balances,
        ) {
            by_runtime.insert("dsh".into(), card);
        }
    }
    if cli_settings.grok_enabled {
        if let Some(card) = generic_acp_usage(
            &state.store,
            "grok",
            "grok",
            "Grok",
            &["XAI_API_KEY", "GROK_API_KEY"],
            &[".grok"],
        ) {
            by_runtime.insert("grok".into(), card);
        }
    }
    if cli_settings.kimi_enabled {
        if let Some(card) = generic_acp_usage(
            &state.store,
            "kimi",
            "kimi",
            "Kimi",
            &["KIMI_API_KEY", "MOONSHOT_API_KEY"],
            &[".kimi"],
        ) {
            by_runtime.insert("kimi".into(), card);
        }
    }

    // Assemble in the user's configured runtimeOrder, then append custom providers.
    let mut configured: Vec<ProviderUsage> = Vec::new();
    let mut signed_out_fallbacks: Vec<ProviderUsage> = Vec::new();

    for id in &cli_settings.runtime_order {
        if let Some(card) = by_runtime.remove(id) {
            if card.status == "signedOut" {
                signed_out_fallbacks.push(card);
            } else {
                configured.push(card);
            }
        }
    }
    for (_, card) in by_runtime {
        if card.status == "signedOut" {
            signed_out_fallbacks.push(card);
        } else {
            configured.push(card);
        }
    }
    configured.extend(custom_cards);

    let providers = if configured.is_empty() {
        signed_out_fallbacks
    } else {
        configured
    };

    let snapshot = UsageSnapshot {
        providers,
        fetched_at: chrono::Utc::now().timestamp_millis(),
    };
    *CACHE.lock().unwrap() = Some(Cache {
        at: Instant::now(),
        snapshot: snapshot.clone(),
    });
    Ok(snapshot)
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn non_empty_env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn num(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn str_of(v: &Value) -> Option<String> {
    v.as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn spend_from_rollup(r: &UsageRollup) -> Option<UsageSpend> {
    if r.is_empty() {
        return None;
    }
    Some(UsageSpend {
        today_tokens: r.today_tokens,
        today_cost_usd: (r.today_cost_usd > 0.0).then_some(r.today_cost_usd),
        week_tokens: r.week_tokens,
        week_cost_usd: (r.week_cost_usd > 0.0).then_some(r.week_cost_usd),
        cache_hit_pct: r.cache_hit_pct(),
    })
}

fn append_top_models(details: &mut Vec<UsageDetail>, models: &[ModelUsageRollup]) {
    for m in models.iter().take(3) {
        let value = if m.cost_usd > 0.0 {
            format!("{} · {}", format_usd(m.cost_usd), compact_tokens(m.tokens))
        } else {
            compact_tokens(m.tokens)
        };
        details.push(UsageDetail {
            label: short_model_name(&m.model),
            value,
        });
    }
}

fn short_model_name(raw: &str) -> String {
    let trimmed = raw.trim();
    match trimmed.split_once('/') {
        Some((_, model)) if !model.is_empty() => model.to_string(),
        _ => trimmed.to_string(),
    }
}

fn compact_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M tok", (n as f64) / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K tok", (n as f64) / 1_000.0)
    } else {
        format!("{n} tok")
    }
}

fn format_usd(n: f64) -> String {
    if n >= 0.01 {
        format!("${:.2}", n)
    } else if n > 0.0 {
        format!("${:.4}", n)
    } else {
        "$0.00".into()
    }
}

fn currency_symbol(currency: &str) -> &'static str {
    match currency.trim().to_ascii_uppercase().as_str() {
        "CNY" | "RMB" => "¥",
        "EUR" => "€",
        "GBP" => "£",
        _ => "$",
    }
}

fn start_of_today_local_ms() -> i64 {
    let now = chrono::Local::now();
    now.date_naive()
        .and_hms_opt(0, 0, 0)
        .and_then(|dt| dt.and_local_timezone(chrono::Local).single())
        .map(|dt| dt.timestamp_millis())
        .unwrap_or_else(|| now.timestamp_millis() - 86_400_000)
}

fn seven_days_ago_local_ms() -> i64 {
    start_of_today_local_ms() - 6 * 86_400_000
}

// ── DeepSeek balance & built-in Cetus (`pi`) ───────────────────────────────

fn resolve_pi_deepseek_key() -> Option<String> {
    crate::secrets::get("deepseek")
        .ok()
        .flatten()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| non_empty_env("DEEPSEEK_API_KEY"))
}

fn parse_deepseek_balance(body: &Value) -> Option<UsageBalance> {
    let infos = body.get("balance_infos")?.as_array()?;
    if infos.is_empty() {
        return None;
    }
    // Prefer an entry with positive balance; otherwise take CNY or first entry.
    let chosen = infos
        .iter()
        .find(|i| num(&i["total_balance"]).unwrap_or(0.0) > 0.0)
        .or_else(|| {
            infos
                .iter()
                .find(|i| str_of(&i["currency"]).as_deref() == Some("CNY"))
        })
        .unwrap_or(&infos[0]);
    let currency = str_of(&chosen["currency"]).unwrap_or_else(|| "CNY".into());
    let sym = currency_symbol(&currency);
    let total = num(&chosen["total_balance"])?;
    let granted = num(&chosen["granted_balance"]).unwrap_or(0.0);
    let note = (granted > 0.0).then(|| format!("incl. {sym}{:.2} granted", granted));
    Some(UsageBalance {
        amount: format!("{sym}{:.2}", total),
        note,
    })
}

async fn fetch_deepseek_balance(
    client: &reqwest::Client,
    base_url: &str,
    api_key: &str,
) -> Result<UsageBalance, String> {
    let base = base_url.trim_end_matches('/').trim_end_matches("/v1");
    let res = client
        .get(format!("{base}/user/balance"))
        .bearer_auth(api_key)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| format!("Couldn't reach DeepSeek ({e})"))?;
    if !res.status().is_success() {
        return Err(format!("DeepSeek balance API returned {}", res.status()));
    }
    let body: Value = res
        .json()
        .await
        .map_err(|e| format!("Unreadable DeepSeek balance ({e})"))?;
    parse_deepseek_balance(&body).ok_or_else(|| "No balance field in DeepSeek response".into())
}

fn pi_usage(
    store: &Store,
    api_key: Option<&str>,
    is_official: bool,
    ds_balances: &HashMap<String, Result<UsageBalance, String>>,
) -> Option<ProviderUsage> {
    let rollup = store.query_usage_rollup("pi").unwrap_or_default();
    let Some(key) = api_key else {
        if rollup.is_empty() {
            return None;
        }
        let mut card = ProviderUsage::new("pi", "cetus", "Cetus · DeepSeek", "metered", "ok");
        card.plan = Some("API".into());
        card.spend = spend_from_rollup(&rollup);
        append_top_models(&mut card.details, &rollup.top_models);
        return Some(card);
    };

    let balance_res = is_official.then(|| ds_balances.get(key)).flatten();
    let mut card = match balance_res {
        Some(Ok(bal)) => {
            let mut c = ProviderUsage::new("pi", "cetus", "Cetus · DeepSeek", "balance", "ok");
            c.plan = Some("API".into());
            c.balance = Some(bal.clone());
            c
        }
        Some(Err(_)) | None => {
            let mut c = ProviderUsage::new("pi", "cetus", "Cetus · DeepSeek", "metered", "ok");
            c.plan = Some(
                if is_official {
                    "API"
                } else {
                    "Custom endpoint"
                }
                .into(),
            );
            c
        }
    };
    if let Some(custom_url) = crate::provider::deepseek_base_url(store) {
        card.account = Some(custom_url);
    }
    card.spend = spend_from_rollup(&rollup);
    append_top_models(&mut card.details, &rollup.top_models);
    Some(card)
}

// ── Claude Code ────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeOauth {
    access_token: Option<String>,
    expires_at: Option<i64>,
    subscription_type: Option<String>,
    rate_limit_tier: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeCredentials {
    claude_ai_oauth: Option<ClaudeOauth>,
}

fn parse_claude_credentials(raw: &str) -> Option<ClaudeOauth> {
    let creds: ClaudeCredentials = serde_json::from_str(raw).ok()?;
    let oauth = creds.claude_ai_oauth?;
    oauth.access_token.as_deref().filter(|t| !t.is_empty())?;
    Some(oauth)
}

async fn security_lookup(args: &[&str]) -> Option<String> {
    let out = tokio::time::timeout(
        Duration::from_secs(3),
        tokio::process::Command::new("/usr/bin/security")
            .args(args)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?;
    let s = s.trim();
    (!s.is_empty()).then(|| s.to_string())
}

async fn claude_credentials() -> Option<ClaudeOauth> {
    let user = std::env::var("USER").unwrap_or_default();
    let account = if !user.is_empty()
        && user
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
    {
        user
    } else {
        "claude-code-user".to_string()
    };
    if cfg!(target_os = "macos") {
        let lookups: [Vec<&str>; 2] = [
            vec![
                "find-generic-password",
                "-a",
                &account,
                "-w",
                "-s",
                CLAUDE_KEYCHAIN_SERVICE,
            ],
            vec!["find-generic-password", "-w", "-s", CLAUDE_KEYCHAIN_SERVICE],
        ];
        for args in lookups {
            if let Some(oauth) = security_lookup(&args)
                .await
                .as_deref()
                .and_then(parse_claude_credentials)
            {
                return Some(oauth);
            }
        }
    }
    let dir = std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(|| home().map(|h| h.join(".claude")))?;
    let raw = tokio::fs::read_to_string(dir.join(".credentials.json"))
        .await
        .ok()?;
    parse_claude_credentials(&raw)
}

fn claude_has_api_key_config() -> Option<String> {
    if non_empty_env("ANTHROPIC_API_KEY").is_some() {
        return Some(
            non_empty_env("ANTHROPIC_BASE_URL").unwrap_or_else(|| "ANTHROPIC_API_KEY".into()),
        );
    }
    let dir = std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(|| home().map(|h| h.join(".claude")))?;
    let raw = std::fs::read_to_string(dir.join("settings.json")).ok()?;
    let v: Value = serde_json::from_str(&raw).ok()?;
    if v.get("apiKeyHelper")
        .and_then(Value::as_str)
        .is_some_and(|s| !s.trim().is_empty())
    {
        return Some("apiKeyHelper".into());
    }
    let env = v.get("env")?;
    if str_of(&env["ANTHROPIC_API_KEY"]).is_some() || str_of(&env["ANTHROPIC_AUTH_TOKEN"]).is_some()
    {
        return Some(str_of(&env["ANTHROPIC_BASE_URL"]).unwrap_or_else(|| "API Key".into()));
    }
    None
}

/// "max" + "default_claude_max_20x" → "Max 20x".
fn claude_plan(subscription: Option<&str>, tier: Option<&str>) -> Option<String> {
    let sub = subscription.filter(|s| !s.is_empty())?;
    let mut label = sub[..1].to_uppercase() + &sub[1..];
    if let Some(last) = tier
        .and_then(|t| t.rsplit('_').next())
        .filter(|s| !s.is_empty())
    {
        if last.to_lowercase() != sub.to_lowercase() {
            label.push(' ');
            label.push_str(last);
        }
    }
    Some(label)
}

fn claude_window(id: &str, label: &str, v: &Value) -> Option<UsageWindow> {
    if !v.is_object() {
        return None;
    }
    Some(UsageWindow {
        id: id.to_string(),
        label: label.to_string(),
        used_pct: num(&v["utilization"]),
        resets_at: str_of(&v["resets_at"]),
    })
}

fn claude_windows(resp: &Value) -> Vec<UsageWindow> {
    let mut out: Vec<UsageWindow> = [("five_hour", "Session (5h)"), ("seven_day", "Weekly")]
        .iter()
        .filter_map(|(field, label)| claude_window(field, label, &resp[*field]))
        .collect();
    let mut scoped: Vec<UsageWindow> = [("seven_day_opus", "Opus")]
        .iter()
        .filter_map(|(field, name)| {
            claude_window(
                &format!("weekly_{}", name.to_lowercase()),
                &format!("Weekly · {name}"),
                &resp[*field],
            )
        })
        .collect();
    for entry in resp["limits"].as_array().into_iter().flatten() {
        if entry["kind"].as_str() != Some("weekly_scoped") {
            continue;
        }
        let name = ["model", "surface"].iter().find_map(|d| {
            let s = &entry["scope"][*d];
            str_of(&s["display_name"]).or_else(|| str_of(&s["id"]))
        });
        let Some(name) = name else { continue };
        let id = format!(
            "weekly_{}",
            name.to_lowercase()
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
                .collect::<String>()
        );
        let w = UsageWindow {
            id: id.clone(),
            label: format!("Weekly · {name}"),
            used_pct: num(&entry["percent"]),
            resets_at: str_of(&entry["resets_at"]),
        };
        match scoped.iter_mut().find(|s| s.id == id) {
            Some(prev) => {
                prev.used_pct = w.used_pct.or(prev.used_pct);
                prev.resets_at = w.resets_at.or(prev.resets_at.take());
                prev.label = w.label;
            }
            None => scoped.push(w),
        }
    }
    out.extend(scoped);
    out
}

async fn claude_get(
    client: &reqwest::Client,
    token: &str,
    path: &str,
) -> Result<reqwest::Response, String> {
    client
        .get(format!("https://api.anthropic.com/api/oauth/{path}"))
        .bearer_auth(token)
        .header("Accept", "application/json")
        .header("anthropic-beta", CLAUDE_OAUTH_BETA)
        .send()
        .await
        .map_err(|e| format!("Couldn't reach Anthropic ({e})"))
}

async fn claude_usage(client: &reqwest::Client, store: &Store) -> ProviderUsage {
    const ID: &str = "claude-code";
    const KIND: &str = "claude";
    const NAME: &str = "Claude";
    let rollup = store.query_usage_rollup("claude-code").unwrap_or_default();

    let Some(oauth) = claude_credentials().await else {
        if let Some(api_source) = claude_has_api_key_config() {
            let mut card = ProviderUsage::new(ID, KIND, NAME, "metered", "ok");
            card.plan = Some("API".into());
            if api_source != "API Key" && api_source != "ANTHROPIC_API_KEY" {
                card.account = Some(api_source);
            }
            card.spend = spend_from_rollup(&rollup);
            append_top_models(&mut card.details, &rollup.top_models);
            return card;
        }
        if !rollup.is_empty() {
            let mut card = ProviderUsage::new(ID, KIND, NAME, "metered", "ok");
            card.plan = Some("API".into());
            card.spend = spend_from_rollup(&rollup);
            append_top_models(&mut card.details, &rollup.top_models);
            return card;
        }
        return ProviderUsage::new(ID, KIND, NAME, "subscription", "signedOut");
    };

    let mut report = ProviderUsage::new(ID, KIND, NAME, "subscription", "ok");
    report.plan = claude_plan(
        oauth.subscription_type.as_deref(),
        oauth.rate_limit_tier.as_deref(),
    );
    if oauth
        .expires_at
        .is_some_and(|ms| ms <= chrono::Utc::now().timestamp_millis())
    {
        report.status = "expired";
        return report;
    }
    if let Some(until) = *CLAUDE_LIMITED_UNTIL.lock().unwrap() {
        if until > Instant::now() {
            let mins = (until - Instant::now()).as_secs().div_ceil(60).max(1);
            return ProviderUsage::failed(
                ID,
                KIND,
                NAME,
                "subscription",
                format!("Rate limited by Claude. Try again in {mins}m."),
            );
        }
    }
    let token = oauth.access_token.unwrap_or_default();
    let (usage, profile) = tokio::join!(
        claude_get(client, &token, "usage"),
        claude_get(client, &token, "profile")
    );
    let res = match usage {
        Ok(r) => r,
        Err(e) => return ProviderUsage::failed(ID, KIND, NAME, "subscription", e),
    };
    match res.status().as_u16() {
        401 | 403 => {
            report.status = "expired";
            return report;
        }
        429 => {
            let wait = res
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(600);
            *CLAUDE_LIMITED_UNTIL.lock().unwrap() =
                Some(Instant::now() + Duration::from_secs(wait));
            return ProviderUsage::failed(
                ID,
                KIND,
                NAME,
                "subscription",
                "Rate limited by Claude. Try again later.".into(),
            );
        }
        s if !(200..300).contains(&s) => {
            return ProviderUsage::failed(
                ID,
                KIND,
                NAME,
                "subscription",
                format!("Claude usage API returned {s}"),
            );
        }
        _ => {}
    }
    let body: Value = match res.json().await {
        Ok(v) => v,
        Err(e) => {
            return ProviderUsage::failed(
                ID,
                KIND,
                NAME,
                "subscription",
                format!("Unreadable Claude usage response ({e})"),
            )
        }
    };
    report.windows = claude_windows(&body);
    if let Some(enabled) = body["extra_usage"]["is_enabled"].as_bool() {
        report.details.push(UsageDetail {
            label: "Extra usage".into(),
            value: if enabled { "Enabled" } else { "Disabled" }.into(),
        });
    }
    if let Ok(r) = profile {
        if r.status().is_success() {
            if let Ok(v) = r.json::<Value>().await {
                report.account = str_of(&v["account"]["email"]);
            }
        }
    }
    report
}

// ── Codex ──────────────────────────────────────────────────────────────────

fn codex_auth_path() -> Option<PathBuf> {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| home().map(|h| h.join(".codex")))
        .map(|d| d.join("auth.json"))
}

fn duration_label(secs: Option<f64>, fallback: &str) -> (String, String) {
    match secs.map(|s| s as i64) {
        Some(604_800) => ("weekly".into(), "Weekly".into()),
        Some(18_000) => ("five_hour".into(), "Session (5h)".into()),
        Some(s) if s > 0 && s % 86_400 == 0 => (format!("{s}s"), format!("{}-day", s / 86_400)),
        Some(s) if s > 0 && s % 3_600 == 0 => (format!("{s}s"), format!("{}-hour", s / 3_600)),
        _ => (
            fallback.to_lowercase().replace(' ', "_"),
            fallback.to_string(),
        ),
    }
}

fn codex_windows(rate_limit: &Value, scope: Option<&str>) -> Vec<UsageWindow> {
    [
        ("primary_window", "Primary limit"),
        ("secondary_window", "Secondary limit"),
    ]
    .iter()
    .filter_map(|(slot, fallback)| {
        let w = &rate_limit[*slot];
        if !w.is_object() {
            return None;
        }
        let (id, label) = duration_label(num(&w["limit_window_seconds"]), fallback);
        let resets_at = num(&w["reset_at"])
            .and_then(|s| chrono::DateTime::from_timestamp(s as i64, 0))
            .map(|d| d.to_rfc3339());
        Some(UsageWindow {
            id: scope.map_or(id.clone(), |s| format!("{s}:{id}")),
            label: scope.map_or(label.clone(), |s| format!("{s} · {label}")),
            used_pct: num(&w["used_percent"]),
            resets_at,
        })
    })
    .collect()
}

async fn codex_usage(client: &reqwest::Client, store: &Store) -> ProviderUsage {
    const ID: &str = "codex";
    const KIND: &str = "codex";
    const NAME: &str = "Codex";
    let rollup = store.query_usage_rollup("codex").unwrap_or_default();

    let auth: Value = match codex_auth_path() {
        Some(path) => tokio::fs::read_to_string(&path)
            .await
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or(Value::Null),
        None => Value::Null,
    };

    let Some(token) = str_of(&auth["tokens"]["access_token"]) else {
        let has_api_key =
            str_of(&auth["OPENAI_API_KEY"]).is_some() || non_empty_env("OPENAI_API_KEY").is_some();
        if has_api_key || !rollup.is_empty() {
            let mut card = ProviderUsage::new(ID, KIND, NAME, "metered", "ok");
            card.plan = Some("API".into());
            card.spend = spend_from_rollup(&rollup);
            return card;
        }
        return ProviderUsage::new(ID, KIND, NAME, "subscription", "signedOut");
    };

    let mut req = client
        .get("https://chatgpt.com/backend-api/wham/usage")
        .bearer_auth(token)
        .header("Accept", "application/json")
        .header(
            "User-Agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        );
    if let Some(id) = str_of(&auth["tokens"]["account_id"]) {
        req = req.header("ChatGPT-Account-Id", id);
    }
    let res = match req.send().await {
        Ok(r) => r,
        Err(e) => {
            return ProviderUsage::failed(
                ID,
                KIND,
                NAME,
                "subscription",
                format!("Couldn't reach ChatGPT ({e})"),
            )
        }
    };
    match res.status().as_u16() {
        401 | 403 => return ProviderUsage::new(ID, KIND, NAME, "subscription", "expired"),
        s if !(200..300).contains(&s) => {
            return ProviderUsage::failed(
                ID,
                KIND,
                NAME,
                "subscription",
                format!("Codex usage API returned {s}"),
            );
        }
        _ => {}
    }
    let text = res.text().await.unwrap_or_default();
    if text.trim_start().starts_with('<') {
        return ProviderUsage::failed(
            ID,
            KIND,
            NAME,
            "subscription",
            "Codex usage API returned HTML".into(),
        );
    }
    let body: Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(e) => {
            return ProviderUsage::failed(
                ID,
                KIND,
                NAME,
                "subscription",
                format!("Unreadable Codex usage response ({e})"),
            )
        }
    };
    let mut report = ProviderUsage::new(ID, KIND, NAME, "subscription", "ok");
    report.plan = str_of(&body["plan_type"]);
    report.account = str_of(&body["email"]);
    report.windows = codex_windows(&body["rate_limit"], None);
    for extra in body["additional_rate_limits"]
        .as_array()
        .into_iter()
        .flatten()
    {
        if let Some(name) =
            str_of(&extra["limit_name"]).or_else(|| str_of(&extra["metered_feature"]))
        {
            report
                .windows
                .extend(codex_windows(&extra["rate_limit"], Some(&name)));
        }
    }
    report.windows.extend(codex_windows(
        &body["code_review_rate_limit"],
        Some("Code review"),
    ));
    if let Some(balance) = num(&body["credits"]["balance"]) {
        report.details.push(UsageDetail {
            label: "Credits".into(),
            value: format!("{} left", format_number(balance)),
        });
    }
    report
}

// ── OpenCode (`~/.local/share/opencode/opencode.db`) ───────────────────────

fn opencode_data_dir() -> Option<PathBuf> {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| home().map(|h| h.join(".local/share")))
        .map(|d| d.join("opencode"))
}

fn read_opencode_db(db_path: &Path, today_start_ms: i64, since_ms: i64) -> Option<ProviderUsage> {
    if !db_path.is_file() {
        return None;
    }
    let conn = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    let _ = conn.busy_timeout(Duration::from_millis(500));

    let mut stmt = conn
        .prepare(
            "SELECT model, cost, tokens_input, tokens_output, tokens_reasoning,
                    tokens_cache_read, tokens_cache_write, time_updated
             FROM session
             WHERE time_updated >= ?1",
        )
        .ok()?;
    let rows = stmt
        .query_map([since_ms], |r| {
            Ok((
                r.get::<_, Option<String>>(0)?.unwrap_or_default(),
                r.get::<_, f64>(1).unwrap_or(0.0).max(0.0),
                r.get::<_, i64>(2).unwrap_or(0).max(0) as u64,
                r.get::<_, i64>(3).unwrap_or(0).max(0) as u64,
                r.get::<_, i64>(4).unwrap_or(0).max(0) as u64,
                r.get::<_, i64>(5).unwrap_or(0).max(0) as u64,
                r.get::<_, i64>(6).unwrap_or(0).max(0) as u64,
                r.get::<_, i64>(7).unwrap_or(0),
            ))
        })
        .ok()?;

    let mut rollup = UsageRollup::default();
    let mut week_sessions = 0u64;
    let mut by_model: std::collections::BTreeMap<String, (u64, f64)> =
        std::collections::BTreeMap::new();

    for row in rows.flatten() {
        let (model, cost, inp, out, reasoning, cache_read, cache_write, updated) = row;
        let prompt = inp.saturating_add(cache_read).saturating_add(cache_write);
        let tok = prompt.saturating_add(out).saturating_add(reasoning);
        if tok == 0 && cost == 0.0 {
            continue;
        }
        week_sessions += 1;
        rollup.week_tokens = rollup.week_tokens.saturating_add(tok);
        rollup.week_cost_usd += cost;
        rollup.week_prompt_tokens = rollup.week_prompt_tokens.saturating_add(prompt);
        rollup.week_cache_read_tokens = rollup.week_cache_read_tokens.saturating_add(cache_read);
        if updated >= today_start_ms {
            rollup.today_tokens = rollup.today_tokens.saturating_add(tok);
            rollup.today_cost_usd += cost;
        }
        if !model.is_empty() {
            let entry = by_model.entry(model).or_insert((0, 0.0));
            entry.0 = entry.0.saturating_add(tok);
            entry.1 += cost;
        }
    }

    let mut models: Vec<ModelUsageRollup> = by_model
        .into_iter()
        .map(|(model, (tokens, cost_usd))| ModelUsageRollup {
            model,
            tokens,
            cost_usd,
        })
        .collect();
    models.sort_by(|a, b| {
        b.cost_usd
            .total_cmp(&a.cost_usd)
            .then_with(|| b.tokens.cmp(&a.tokens))
    });
    models.truncate(3);
    rollup.top_models = models;

    let account: Option<String> = conn
        .query_row(
            "SELECT a.email FROM account a
             JOIN account_state s ON s.active_account_id = a.id
             LIMIT 1",
            [],
            |r| r.get(0),
        )
        .ok()
        .or_else(|| {
            conn.query_row(
                "SELECT email FROM control_account WHERE active = 1 LIMIT 1",
                [],
                |r| r.get(0),
            )
            .ok()
        });

    let mut card = ProviderUsage::new("opencode", "opencode", "OpenCode", "metered", "ok");
    card.account = account;
    card.spend = spend_from_rollup(&rollup);
    if week_sessions > 0 {
        card.details.push(UsageDetail {
            label: "Sessions (7d)".into(),
            value: week_sessions.to_string(),
        });
    }
    append_top_models(&mut card.details, &rollup.top_models);
    Some(card)
}

fn opencode_usage(store: &Store) -> Option<ProviderUsage> {
    let dir = opencode_data_dir()?;
    let auth_providers = std::fs::read_to_string(dir.join("auth.json"))
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .and_then(|v| v.as_object().map(|m| m.len()))
        .unwrap_or(0);

    if let Some(mut card) = read_opencode_db(
        &dir.join("opencode.db"),
        start_of_today_local_ms(),
        seven_days_ago_local_ms(),
    ) {
        if auth_providers > 0 {
            card.plan = Some(if auth_providers == 1 {
                "1 provider".into()
            } else {
                format!("{auth_providers} providers")
            });
        } else {
            card.plan = Some("Metered".into());
        }
        return Some(card);
    }

    let rollup = store.query_usage_rollup("opencode").unwrap_or_default();
    if auth_providers == 0 && rollup.is_empty() {
        return None;
    }
    let mut card = ProviderUsage::new("opencode", "opencode", "OpenCode", "metered", "ok");
    card.plan = Some("Metered".into());
    card.spend = spend_from_rollup(&rollup);
    append_top_models(&mut card.details, &rollup.top_models);
    Some(card)
}

// ── DeepSeek Harness (`dsh`) ───────────────────────────────────────────────

fn dsh_home_dir() -> Option<PathBuf> {
    std::env::var_os("DSH_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| home().map(|h| h.join(".dsh")))
}

fn resolve_dsh_deepseek_key() -> Option<String> {
    let path = dsh_home_dir()?.join(".env");
    let text = std::fs::read_to_string(path).ok()?;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        if k.trim() == "DEEPSEEK_API_KEY" {
            let val = v.trim().trim_matches('"').trim_matches('\'').trim();
            if !val.is_empty() {
                return Some(val.to_string());
            }
        }
    }
    None
}

fn scan_dsh_sessions(
    sessions_root: &Path,
    today_start_ms: i64,
    since_ms: i64,
) -> (UsageRollup, u64) {
    let mut rollup = UsageRollup::default();
    let mut session_count = 0u64;
    let since_sys = UNIX_EPOCH + Duration::from_millis(since_ms.max(0) as u64);

    let Ok(projects) = std::fs::read_dir(sessions_root) else {
        return (rollup, 0);
    };
    for proj in projects.flatten() {
        let Ok(sessions) = std::fs::read_dir(proj.path()) else {
            continue;
        };
        for sess in sessions.flatten() {
            let zst_path = sess.path().join("session.jsonl.zstd");
            let jsonl_path = sess.path().join("session.jsonl");
            let (path, compressed) = if zst_path.is_file() {
                (zst_path, true)
            } else if jsonl_path.is_file() {
                (jsonl_path, false)
            } else {
                continue;
            };
            if let Ok(meta) = std::fs::metadata(&path) {
                if let Ok(modified) = meta.modified() {
                    if modified < since_sys {
                        continue;
                    }
                }
            }
            let Ok(file) = std::fs::File::open(&path) else {
                continue;
            };
            let reader: Box<dyn BufRead> = if compressed {
                match zstd::stream::read::Decoder::new(file) {
                    Ok(dec) => Box::new(std::io::BufReader::new(dec)),
                    Err(_) => continue,
                }
            } else {
                Box::new(std::io::BufReader::new(file))
            };
            let mut counted_session = false;
            for line in reader.lines().map_while(Result::ok) {
                if !line.contains("\"assistant/message\"") {
                    continue;
                }
                let Ok(v) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                if v.get("type").and_then(Value::as_str) != Some("assistant/message") {
                    continue;
                }
                let ts = v
                    .get("time")
                    .and_then(|t| {
                        t.as_i64().or_else(|| {
                            t.as_str()
                                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                                .map(|dt| dt.timestamp_millis())
                        })
                    })
                    .unwrap_or(since_ms);
                if ts < since_ms {
                    continue;
                }
                let Some(usage) = v.pointer("/data/usage") else {
                    continue;
                };
                let u = |k: &str| usage.get(k).and_then(Value::as_u64).unwrap_or(0);
                let inp = u("inputTokens");
                let out = u("outputTokens");
                let cache_read = u("cacheReadTokens");
                let prompt = inp.saturating_add(cache_read);
                let tok = u("totalTokens").max(prompt.saturating_add(out));
                if tok == 0 {
                    continue;
                }
                counted_session = true;
                rollup.week_tokens = rollup.week_tokens.saturating_add(tok);
                rollup.week_prompt_tokens = rollup.week_prompt_tokens.saturating_add(prompt);
                rollup.week_cache_read_tokens =
                    rollup.week_cache_read_tokens.saturating_add(cache_read);
                if ts >= today_start_ms {
                    rollup.today_tokens = rollup.today_tokens.saturating_add(tok);
                }
            }
            if counted_session {
                session_count += 1;
            }
        }
    }
    (rollup, session_count)
}

fn dsh_usage(
    store: &Store,
    dsh_key: Option<&str>,
    shared_with_cetus: bool,
    ds_balances: &HashMap<String, Result<UsageBalance, String>>,
) -> Option<ProviderUsage> {
    let dir = dsh_home_dir()?;
    let (mut rollup, session_count) = if dir.join("sessions").is_dir() {
        scan_dsh_sessions(
            &dir.join("sessions"),
            start_of_today_local_ms(),
            seven_days_ago_local_ms(),
        )
    } else {
        (UsageRollup::default(), 0)
    };
    if rollup.is_empty() {
        rollup = store.query_usage_rollup("dsh").unwrap_or_default();
    }

    let has_config = dsh_key.is_some() || dir.join("settings.yaml").is_file() || !rollup.is_empty();
    if !has_config {
        return None;
    }

    let balance = dsh_key
        .and_then(|k| ds_balances.get(k))
        .and_then(|res| res.as_ref().ok())
        .cloned()
        .map(|mut bal| {
            if shared_with_cetus {
                bal.note = Some(match bal.note {
                    Some(existing) => format!("{existing} · shared with Cetus"),
                    None => "Shared with Cetus".into(),
                });
            }
            bal
        });

    let billing = if balance.is_some() {
        "balance"
    } else {
        "metered"
    };
    let mut card = ProviderUsage::new("dsh", "dsh", "DeepSeek Harness", billing, "ok");
    card.plan = Some("API".into());
    card.balance = balance;
    card.spend = spend_from_rollup(&rollup);
    if session_count > 0 {
        card.details.push(UsageDetail {
            label: "Sessions (7d)".into(),
            value: session_count.to_string(),
        });
    }
    Some(card)
}

// ── Antigravity (`agy`) ────────────────────────────────────────────────────

#[derive(Default)]
struct AgyLocalConfig {
    auth_type: Option<String>,
    gcp_project: Option<String>,
    gcp_location: Option<String>,
    has_api_key: bool,
    oauth_token: Option<String>,
}

fn load_antigravity_config() -> AgyLocalConfig {
    let mut cfg = AgyLocalConfig::default();
    let Some(h) = home() else { return cfg };

    // Cetus-scoped Antigravity env file (`~/.config/cetus/antigravity/env.json`).
    if let Ok(raw) = std::fs::read_to_string(h.join(".config/cetus/antigravity/env.json")) {
        if let Ok(env) = serde_json::from_str::<HashMap<String, String>>(&raw) {
            if env
                .get("GEMINI_API_KEY")
                .or_else(|| env.get("GOOGLE_API_KEY"))
                .is_some_and(|v| !v.trim().is_empty())
            {
                cfg.has_api_key = true;
            }
            if let Some(p) = env
                .get("GOOGLE_CLOUD_PROJECT")
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
            {
                cfg.gcp_project = Some(p.to_string());
            }
            if let Some(loc) = env
                .get("GOOGLE_CLOUD_LOCATION")
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
            {
                cfg.gcp_location = Some(loc.to_string());
            }
        }
    }

    // Native `agy` settings (`~/.gemini/antigravity-cli/settings.json`).
    let agy_dir = h.join(".gemini/antigravity-cli");
    if let Ok(raw) = std::fs::read_to_string(agy_dir.join("settings.json")) {
        if let Ok(v) = serde_json::from_str::<Value>(&raw) {
            cfg.auth_type = str_of(&v["auth"]["type"]);
            if cfg.gcp_project.is_none() {
                cfg.gcp_project = str_of(&v["gcp"]["project"]);
            }
            if cfg.gcp_location.is_none() {
                cfg.gcp_location = str_of(&v["gcp"]["location"]);
            }
        }
    }

    // Non-prompting OAuth token lookup (never touches macOS Keychain ACLs owned
    // by `agy`, avoiding unexpected OS password prompts): checks env or file
    // fallback credentials when present.
    cfg.oauth_token = non_empty_env("JETSKI_OAUTH_TOKEN").or_else(|| {
        for candidate in [
            agy_dir.join("oauth_creds.json"),
            agy_dir.join("credentials.json"),
            h.join(".gemini/oauth_creds.json"),
        ] {
            let Ok(raw) = std::fs::read_to_string(candidate) else {
                continue;
            };
            let Ok(v) = serde_json::from_str::<Value>(&raw) else {
                continue;
            };
            let expired = v
                .get("expiry_date")
                .and_then(Value::as_i64)
                .is_some_and(|ms| ms <= chrono::Utc::now().timestamp_millis());
            if expired {
                continue;
            }
            if let Some(tok) = str_of(&v["access_token"]) {
                return Some(tok);
            }
        }
        None
    });

    cfg
}

fn parse_antigravity_quota_windows(body: &Value) -> Vec<UsageWindow> {
    let Some(models) = body.get("models").and_then(Value::as_object) else {
        return Vec::new();
    };
    let mut windows = Vec::new();
    for (id, entry) in models {
        let Some(quota) = entry.get("quotaInfo").or_else(|| entry.get("quota_info")) else {
            continue;
        };
        let remaining =
            num(&quota["remainingFraction"]).or_else(|| num(&quota["remaining_fraction"]));
        let Some(rem) = remaining else { continue };
        let used_pct = ((1.0 - rem.clamp(0.0, 1.0)) * 100.0).clamp(0.0, 100.0);
        let label = str_of(&entry["displayName"])
            .or_else(|| str_of(&entry["display_name"]))
            .unwrap_or_else(|| id.clone());
        let resets_at = str_of(&quota["resetTime"]).or_else(|| str_of(&quota["reset_time"]));
        windows.push(UsageWindow {
            id: id.clone(),
            label,
            used_pct: Some(used_pct),
            resets_at,
        });
    }
    windows.sort_by(|a, b| {
        b.used_pct
            .unwrap_or(0.0)
            .total_cmp(&a.used_pct.unwrap_or(0.0))
            .then_with(|| a.label.cmp(&b.label))
    });
    windows.truncate(4);
    windows
}

async fn fetch_antigravity_quota(
    client: &reqwest::Client,
    token: &str,
    project: Option<&str>,
) -> Option<Vec<UsageWindow>> {
    let payload = match project {
        Some(p) if !p.is_empty() => serde_json::json!({ "project": p }),
        _ => serde_json::json!({}),
    };
    let res = client
        .post("https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")
        .bearer_auth(token)
        .header("Accept", "application/json")
        .json(&payload)
        .send()
        .await
        .ok()?;
    if !res.status().is_success() {
        return None;
    }
    let body: Value = res.json().await.ok()?;
    let windows = parse_antigravity_quota_windows(&body);
    (!windows.is_empty()).then_some(windows)
}

fn read_antigravity_activity(db_path: &Path) -> Option<(u64, u64, u64, u64)> {
    if !db_path.is_file() {
        return None;
    }
    let conn = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    let _ = conn.busy_timeout(Duration::from_millis(500));
    let (today_chats, today_steps): (i64, i64) = conn
        .query_row(
            "SELECT COUNT(*), COALESCE(SUM(step_count), 0)
             FROM conversation_summaries
             WHERE last_modified_time >= datetime('now', 'start of day')",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap_or((0, 0));
    let (week_chats, week_steps): (i64, i64) = conn
        .query_row(
            "SELECT COUNT(*), COALESCE(SUM(step_count), 0)
             FROM conversation_summaries
             WHERE last_modified_time >= datetime('now', '-7 days')",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap_or((0, 0));
    if today_chats == 0 && week_chats == 0 {
        return None;
    }
    Some((
        today_chats.max(0) as u64,
        today_steps.max(0) as u64,
        week_chats.max(0) as u64,
        week_steps.max(0) as u64,
    ))
}

async fn antigravity_usage(client: &reqwest::Client, store: &Store) -> Option<ProviderUsage> {
    let cfg = load_antigravity_config();
    let rollup = store.query_usage_rollup("antigravity").unwrap_or_default();
    let activity = home().and_then(|h| {
        read_antigravity_activity(&h.join(".gemini/antigravity-cli/conversation_summaries.db"))
    });

    let is_configured = cfg.auth_type.is_some()
        || cfg.has_api_key
        || cfg.gcp_project.is_some()
        || cfg.oauth_token.is_some()
        || !rollup.is_empty()
        || activity.is_some();
    if !is_configured {
        return None;
    }

    // Consumer / Cloud Code Assist quota probe when a file/env OAuth token exists.
    if let Some(tok) = cfg.oauth_token.as_deref() {
        if let Some(windows) =
            fetch_antigravity_quota(client, tok, cfg.gcp_project.as_deref()).await
        {
            let mut card = ProviderUsage::new(
                "antigravity",
                "antigravity",
                "Antigravity",
                "subscription",
                "ok",
            );
            card.plan = Some("Cloud Code".into());
            card.account = cfg.gcp_project;
            card.windows = windows;
            return Some(card);
        }
    }

    let plan = match cfg.auth_type.as_deref() {
        Some("agent-platform") => {
            if cfg.has_api_key {
                "Vertex AI · Key"
            } else {
                "Vertex AI"
            }
        }
        Some("gemini-api-key") => "API Key",
        Some(other) => other,
        None if cfg.gcp_project.is_some() => "Vertex AI",
        None if cfg.has_api_key => "API Key",
        None => "Metered",
    };

    let mut card = ProviderUsage::new("antigravity", "antigravity", "Antigravity", "metered", "ok");
    card.plan = Some(plan.to_string());
    card.account = match (&cfg.gcp_project, &cfg.gcp_location) {
        (Some(p), Some(loc)) => Some(format!("{p} · {loc}")),
        (Some(p), None) => Some(p.clone()),
        _ => None,
    };
    card.spend = spend_from_rollup(&rollup);
    if let Some((today_chats, today_steps, week_chats, week_steps)) = activity {
        if today_chats > 0 {
            card.details.push(UsageDetail {
                label: "Today".into(),
                value: format!("{today_chats} chats · {today_steps} steps"),
            });
        }
        card.details.push(UsageDetail {
            label: "7-day activity".into(),
            value: format!("{week_chats} chats · {week_steps} steps"),
        });
    }
    append_top_models(&mut card.details, &rollup.top_models);
    Some(card)
}

// ── Generic ACP runtimes (Grok / Kimi) ─────────────────────────────────────

fn generic_acp_usage(
    store: &Store,
    id: &str,
    kind: &'static str,
    name: &str,
    env_vars: &[&str],
    dot_dirs: &[&str],
) -> Option<ProviderUsage> {
    let rollup = store.query_usage_rollup(id).unwrap_or_default();
    let has_env = env_vars.iter().any(|k| non_empty_env(k).is_some());
    let has_dir = home().is_some_and(|h| dot_dirs.iter().any(|d| h.join(d).exists()));
    if !has_env && !has_dir && rollup.is_empty() {
        return None;
    }
    let mut card = ProviderUsage::new(id, kind, name, "metered", "ok");
    card.plan = Some("API".into());
    card.spend = spend_from_rollup(&rollup);
    append_top_models(&mut card.details, &rollup.top_models);
    Some(card)
}

// ── Custom Model Providers (Settings → Models) ─────────────────────────────

struct OpenRouterKeyStats {
    balance: Option<UsageBalance>,
    today_cost: Option<f64>,
    week_cost: Option<f64>,
}

fn parse_openrouter_key(body: &Value) -> Option<OpenRouterKeyStats> {
    let data = body.get("data")?;
    let remaining = num(&data["limit_remaining"]);
    let limit = num(&data["limit"]);
    let balance = remaining.map(|rem| UsageBalance {
        amount: format!("${:.2}", rem),
        note: limit.map(|l| format!("of ${:.2} limit", l)),
    });
    let today_cost = num(&data["usage_daily"]).filter(|v| *v > 0.0);
    let week_cost = num(&data["usage_weekly"]).filter(|v| *v > 0.0);
    if balance.is_none() && today_cost.is_none() && week_cost.is_none() {
        return None;
    }
    Some(OpenRouterKeyStats {
        balance,
        today_cost,
        week_cost,
    })
}

async fn fetch_openrouter_key(
    client: &reqwest::Client,
    base_url: &str,
    api_key: &str,
) -> Option<OpenRouterKeyStats> {
    let root = base_url
        .trim_end_matches('/')
        .trim_end_matches("/v1")
        .trim_end_matches("/api");
    let url = if root.contains("openrouter.ai") {
        "https://openrouter.ai/api/v1/key".to_string()
    } else {
        format!("{root}/api/v1/key")
    };
    let res = client
        .get(url)
        .bearer_auth(api_key)
        .header("Accept", "application/json")
        .send()
        .await
        .ok()?;
    if !res.status().is_success() {
        return None;
    }
    let body: Value = res.json().await.ok()?;
    parse_openrouter_key(&body)
}

async fn collect_custom_providers(
    client: &reqwest::Client,
    store: &Store,
    providers: &[crate::custom_models::CustomProvider],
) -> Vec<ProviderUsage> {
    let mut out = Vec::new();
    for p in providers {
        let scope = format!("custom:{}", p.id);
        let rollup = store.query_usage_rollup(&scope).unwrap_or_default();
        let api_key = crate::secrets::get(&crate::custom_models::secret_id(&p.id))
            .ok()
            .flatten()
            .filter(|k| !k.trim().is_empty());

        let is_openrouter = p.base_url.to_ascii_lowercase().contains("openrouter.ai");
        let is_deepseek = p.base_url.to_ascii_lowercase().contains("api.deepseek.com");

        let mut balance: Option<UsageBalance> = None;
        let mut spend = spend_from_rollup(&rollup);

        if is_openrouter {
            if let Some(key) = api_key.as_deref() {
                if let Some(or_stats) = fetch_openrouter_key(client, &p.base_url, key).await {
                    balance = or_stats.balance;
                    if or_stats.today_cost.is_some() || or_stats.week_cost.is_some() {
                        let base = spend.unwrap_or(UsageSpend {
                            today_tokens: rollup.today_tokens,
                            today_cost_usd: None,
                            week_tokens: rollup.week_tokens,
                            week_cost_usd: None,
                            cache_hit_pct: rollup.cache_hit_pct(),
                        });
                        spend = Some(UsageSpend {
                            today_cost_usd: or_stats.today_cost.or(base.today_cost_usd),
                            week_cost_usd: or_stats.week_cost.or(base.week_cost_usd),
                            ..base
                        });
                    }
                }
            }
        } else if is_deepseek {
            if let Some(key) = api_key.as_deref() {
                if let Ok(bal) = fetch_deepseek_balance(client, &p.base_url, key).await {
                    balance = Some(bal);
                }
            }
        }

        let billing = if balance.is_some() {
            "balance"
        } else {
            "metered"
        };
        let has_pricing = p
            .models
            .iter()
            .any(|m| m.input_price.is_some() || m.output_price.is_some());
        let mut card = ProviderUsage::new(&p.id, "custom", &p.name, billing, "ok");
        card.plan = Some(
            if is_openrouter {
                "OpenRouter"
            } else if has_pricing {
                "Priced API"
            } else {
                "Custom API"
            }
            .into(),
        );
        card.account = Some(p.base_url.clone());
        card.balance = balance;
        card.spend = spend;
        if rollup.top_models.is_empty() {
            let model_names: Vec<String> = p
                .models
                .iter()
                .take(3)
                .map(|m| {
                    if m.name.is_empty() {
                        m.id.clone()
                    } else {
                        m.name.clone()
                    }
                })
                .collect();
            if !model_names.is_empty() {
                card.details.push(UsageDetail {
                    label: "Models".into(),
                    value: model_names.join(", "),
                });
            }
        } else {
            append_top_models(&mut card.details, &rollup.top_models);
        }
        out.push(card);
    }
    out
}

/// 61671.934 → "61,671.93".
fn format_number(n: f64) -> String {
    let fixed = format!("{:.2}", n.abs());
    let (int, frac) = fixed.split_once('.').unwrap_or((&fixed, "00"));
    let mut grouped = String::new();
    for (i, c) in int.chars().enumerate() {
        if i > 0 && (int.len() - i) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(c);
    }
    let frac = frac.trim_end_matches('0');
    let sign = if n < 0.0 { "-" } else { "" };
    if frac.is_empty() {
        format!("{sign}{grouped}")
    } else {
        format!("{sign}{grouped}.{frac}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn plan_label() {
        assert_eq!(
            claude_plan(Some("max"), Some("default_claude_max_20x")).as_deref(),
            Some("Max 20x")
        );
        assert_eq!(claude_plan(Some("pro"), None).as_deref(), Some("Pro"));
        assert_eq!(claude_plan(None, Some("x")), None);
    }

    #[test]
    fn claude_scoped_limits_merge() {
        let resp = json!({
            "five_hour": {"utilization": 12.0, "resets_at": "2026-11-06T12:00:00Z"},
            "seven_day": {"utilization": 31, "resets_at": "2026-11-09T14:59:00Z"},
            "seven_day_opus": {"utilization": 5},
            "limits": [
                {"kind": "weekly_scoped", "percent": 7, "scope": {"model": {"display_name": "Opus"}}},
                {"kind": "weekly_scoped", "percent": 0, "scope": {"model": {"display_name": "Fable"}}},
                {"kind": "other", "percent": 50}
            ]
        });
        let w = claude_windows(&resp);
        let ids: Vec<_> = w.iter().map(|w| w.id.as_str()).collect();
        assert_eq!(
            ids,
            ["five_hour", "seven_day", "weekly_opus", "weekly_fable"]
        );
        assert_eq!(w[2].used_pct, Some(7.0));
        assert_eq!(w[3].label, "Weekly · Fable");
    }

    #[test]
    fn codex_windows_by_duration() {
        let rl = json!({
            "primary_window": {"used_percent": 3, "reset_at": 1_762_000_000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 10, "reset_at": 1_762_400_000, "limit_window_seconds": 604800}
        });
        let w = codex_windows(&rl, None);
        assert_eq!(w[0].label, "Session (5h)");
        assert_eq!(w[1].label, "Weekly");
        assert!(w[1].resets_at.is_some());
    }

    #[test]
    fn deepseek_balance_parses_currency_and_grant() {
        let body = json!({
            "is_available": true,
            "balance_infos": [
                {
                    "currency": "CNY",
                    "total_balance": "48.20",
                    "granted_balance": "10.00",
                    "topped_up_balance": "38.20"
                }
            ]
        });
        let bal = parse_deepseek_balance(&body).unwrap();
        assert_eq!(bal.amount, "¥48.20");
        assert_eq!(bal.note.as_deref(), Some("incl. ¥10.00 granted"));
    }

    #[test]
    fn openrouter_key_parses_balance_and_spend() {
        let body = json!({
            "data": {
                "limit": 50.0,
                "limit_remaining": 31.45,
                "usage_daily": 1.25,
                "usage_weekly": 8.9
            }
        });
        let stats = parse_openrouter_key(&body).unwrap();
        assert_eq!(stats.balance.unwrap().amount, "$31.45");
        assert_eq!(stats.today_cost, Some(1.25));
        assert_eq!(stats.week_cost, Some(8.9));
    }

    #[test]
    fn antigravity_quota_converts_remaining_fraction_to_used_pct() {
        let body = json!({
            "models": {
                "gemini-3-pro": {
                    "displayName": "Gemini 3 Pro",
                    "quotaInfo": {
                        "remainingFraction": 0.25,
                        "resetTime": "2026-11-16T18:00:00Z"
                    }
                }
            }
        });
        let w = parse_antigravity_quota_windows(&body);
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].label, "Gemini 3 Pro");
        assert_eq!(w[0].used_pct, Some(75.0));
    }

    #[test]
    fn opencode_sqlite_reader_aggregates_without_fake_zero_cost() {
        let tmp = std::env::temp_dir().join(format!("opencode-test-{}.db", uuid::Uuid::new_v4()));
        {
            let conn = Connection::open(&tmp).unwrap();
            conn.execute_batch(
                "CREATE TABLE session (
                    id TEXT PRIMARY KEY,
                    model TEXT,
                    cost REAL NOT NULL DEFAULT 0,
                    tokens_input INTEGER NOT NULL DEFAULT 0,
                    tokens_output INTEGER NOT NULL DEFAULT 0,
                    tokens_reasoning INTEGER NOT NULL DEFAULT 0,
                    tokens_cache_read INTEGER NOT NULL DEFAULT 0,
                    tokens_cache_write INTEGER NOT NULL DEFAULT 0,
                    time_updated INTEGER NOT NULL
                );
                CREATE TABLE account (id TEXT PRIMARY KEY, email TEXT NOT NULL);
                CREATE TABLE account_state (id INTEGER PRIMARY KEY, active_account_id TEXT);",
            )
            .unwrap();
            conn.execute(
                "INSERT INTO session VALUES ('s1', 'gcp-gemini/gemini-4-carbon', 0.0, 20000, 1000, 0, 80000, 0, 2000)",
                [],
            )
            .unwrap();
        }
        let card = read_opencode_db(&tmp, 1500, 1000).unwrap();
        let _ = std::fs::remove_file(&tmp);
        let spend = card.spend.unwrap();
        assert_eq!(spend.today_tokens, 101_000);
        assert_eq!(spend.today_cost_usd, None);
        assert_eq!(spend.cache_hit_pct, Some(80));
        assert_eq!(card.details[1].label, "gemini-4-carbon");
    }

    #[test]
    fn number_formatting() {
        assert_eq!(format_number(61671.934), "61,671.93");
        assert_eq!(format_number(1000.0), "1,000");
        assert_eq!(format_number(12.5), "12.5");
    }
}
