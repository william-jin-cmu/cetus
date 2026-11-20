use crate::app_event::AppEvent;
use crate::bridge::RuntimeEvent;
use crate::pi_rpc::{EventSink, TaskSpawner};
use crate::store::usage::UsageDelta;
use host::{AppHandle, Emitter, Manager};
use serde_json::Value;
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Mutex, OnceLock};

fn acp_session_baselines() -> &'static Mutex<HashMap<String, (u64, f64)>> {
    static BASELINES: OnceLock<Mutex<HashMap<String, (u64, f64)>>> = OnceLock::new();
    BASELINES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn record_protocol_usage(state: &crate::AppState, conversation_id: Option<&str>, event: &Value) {
    match event.get("type").and_then(Value::as_str) {
        Some("message_end") => {
            let Some(msg) = event.get("message") else {
                return;
            };
            if msg.get("role").and_then(Value::as_str) != Some("assistant") {
                return;
            }
            let Some(usage) = msg.get("usage") else {
                return;
            };
            let num = |k: &str| {
                usage
                    .get(k)
                    .and_then(|v| v.as_u64().or_else(|| v.as_f64().map(|f| f as u64)))
                    .unwrap_or(0)
            };
            let input = num("input");
            let output = num("output");
            let cache_read = num("cacheRead");
            let cache_write = num("cacheWrite");
            if input + output + cache_read + cache_write == 0 {
                return;
            }
            let mut provider = msg
                .get("provider")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let mut model = msg
                .get("model")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            if provider.is_empty() {
                if let Some(cid) = conversation_id {
                    if let Ok(Some(conv)) = state.store.get(cid) {
                        if let crate::model::ModelRef::Custom {
                            provider: p,
                            model: m,
                        } = conv.model.model
                        {
                            provider = p;
                            if model.is_empty() {
                                model = m;
                            }
                        }
                    }
                }
            }
            let reported_cost = usage
                .pointer("/cost/total")
                .and_then(Value::as_f64)
                .filter(|c| c.is_finite() && *c > 0.0)
                .unwrap_or(0.0);
            let (scope, cost_usd) = if provider.starts_with(crate::custom_models::ID_PREFIX) {
                let est = if reported_cost > 0.0 {
                    reported_cost
                } else {
                    crate::custom_models::find_custom_model(&state.store, &provider, &model)
                        .map(|cm| cm.estimate_cost_usd(input, output, cache_read))
                        .unwrap_or(0.0)
                };
                (format!("custom:{provider}"), est)
            } else {
                ("pi".to_string(), reported_cost)
            };
            let _ = state.store.record_usage_delta(UsageDelta {
                scope: &scope,
                model: &model,
                input_tokens: input,
                output_tokens: output,
                cache_read_tokens: cache_read,
                cache_write_tokens: cache_write,
                cost_usd,
            });
            crate::usage::invalidate_cache();
        }
        Some("cli_context_usage") => {
            if let Some(ledger) = event.get("ledger") {
                let Some(scope) = ledger.get("scope").and_then(Value::as_str) else {
                    return;
                };
                let model = ledger.get("model").and_then(Value::as_str).unwrap_or("");
                let u = |k: &str| ledger.get(k).and_then(Value::as_u64).unwrap_or(0);
                let cost = ledger.get("costUsd").and_then(Value::as_f64).unwrap_or(0.0);
                let _ = state.store.record_usage_delta(UsageDelta {
                    scope,
                    model,
                    input_tokens: u("inputTokens"),
                    output_tokens: u("outputTokens"),
                    cache_read_tokens: u("cacheReadTokens"),
                    cache_write_tokens: u("cacheWriteTokens"),
                    cost_usd: cost,
                });
                crate::usage::invalidate_cache();
                return;
            }
            // ACP `usage_update` carries session-cumulative `usedTokens` and `sessionCostUsd`.
            if let (Some(backend), Some(cid)) = (
                event.get("backend").and_then(Value::as_str),
                conversation_id,
            ) {
                let used = event.get("usedTokens").and_then(Value::as_u64).unwrap_or(0);
                let cost = event
                    .get("sessionCostUsd")
                    .and_then(Value::as_f64)
                    .unwrap_or(0.0);
                let key = format!("{backend}:{cid}");
                let (delta_tok, delta_cost) = {
                    let mut map = acp_session_baselines().lock().unwrap();
                    let prev = map.entry(key).or_insert((0, 0.0));
                    let dt = used.saturating_sub(prev.0);
                    let dc = (cost - prev.1).max(0.0);
                    prev.0 = prev.0.max(used);
                    prev.1 = prev.1.max(cost);
                    (dt, dc)
                };
                if delta_tok > 0 || delta_cost > 0.0 {
                    let model = state
                        .store
                        .get(cid)
                        .ok()
                        .flatten()
                        .map(|c| c.cli_model)
                        .unwrap_or_default();
                    let _ = state.store.record_usage_delta(UsageDelta {
                        scope: backend,
                        model: &model,
                        input_tokens: delta_tok,
                        output_tokens: 0,
                        cache_read_tokens: 0,
                        cache_write_tokens: 0,
                        cost_usd: delta_cost,
                    });
                    crate::usage::invalidate_cache();
                }
            }
        }
        _ => {}
    }
}

#[derive(Clone)]
pub struct HostEventSink {
    handle: AppHandle,
}

impl HostEventSink {
    pub fn new(handle: AppHandle) -> Self {
        Self { handle }
    }
}

impl EventSink for HostEventSink {
    fn emit(&self, event: RuntimeEvent) {
        if let RuntimeEvent::Protocol {
            conversation_id,
            event,
        } = &event
        {
            if let Some(state) = self.handle.try_state::<crate::AppState>() {
                if let Some(cid) = conversation_id.as_deref() {
                    if event.get("type").and_then(Value::as_str) == Some("cli_commands") {
                        let commands = event
                            .get("commands")
                            .and_then(Value::as_array)
                            .cloned()
                            .unwrap_or_default();
                        state.cache_cli_commands(cid, commands);
                    }
                }
                record_protocol_usage(&state, conversation_id.as_deref(), event);
            }
        }
        // Must stay a broadcast `emit`: backend listeners (remote.rs, devtest.rs,
        // and the host-tunnel handlers in lib.rs) subscribe via AppHandle::listen,
        // which registers EventTarget::App and never matches an
        // `emit_to("main")`. Webview listeners use target Any and receive every
        // emit either way, so narrowing the target only silences the backend.
        let _ = self.handle.emit("app-event", AppEvent::from(event));
    }
}

#[derive(Clone)]
pub struct HostTaskSpawner;

impl TaskSpawner for HostTaskSpawner {
    fn spawn(&self, fut: Pin<Box<dyn Future<Output = ()> + Send + 'static>>) {
        host::async_runtime::spawn(fut);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use host::Listener;
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    };

    /// Regression test for v0.3.34→v0.3.51: narrowing the sink to
    /// `emit_to("main")` silently cut off every `AppHandle::listen`
    /// subscriber (Cetus Remote's WebSocket fan-out, devtest, and the
    /// automation/skill/MCP/agent-control host tunnels).
    #[test]
    fn runtime_events_reach_app_handle_listeners() {
        let app = host::test::mock_app();
        let received = Arc::new(AtomicBool::new(false));
        let seen = received.clone();
        app.handle().listen("app-event", move |event| {
            if event.payload().contains("pi_event") {
                seen.store(true, Ordering::SeqCst);
            }
        });
        let sink = HostEventSink::new(app.handle().clone());
        sink.emit(RuntimeEvent::Protocol {
            conversation_id: Some("conv-1".into()),
            event: serde_json::json!({ "type": "message_update" }),
        });
        assert!(received.load(Ordering::SeqCst));
    }
}
