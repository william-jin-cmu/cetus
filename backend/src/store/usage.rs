use super::{now_ms, params, Result, Store};

#[derive(Debug, Clone, Default)]
pub struct UsageDelta<'a> {
    pub scope: &'a str,
    pub model: &'a str,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub cost_usd: f64,
}

#[derive(Debug, Clone, Default)]
pub struct ModelUsageRollup {
    pub model: String,
    pub tokens: u64,
    pub cost_usd: f64,
}

#[derive(Debug, Clone, Default)]
pub struct UsageRollup {
    pub today_tokens: u64,
    pub today_cost_usd: f64,
    pub week_tokens: u64,
    pub week_cost_usd: f64,
    pub week_prompt_tokens: u64,
    pub week_cache_read_tokens: u64,
    pub top_models: Vec<ModelUsageRollup>,
}

impl UsageRollup {
    pub fn is_empty(&self) -> bool {
        self.today_tokens == 0
            && self.week_tokens == 0
            && self.today_cost_usd <= 0.0
            && self.week_cost_usd <= 0.0
    }

    pub fn cache_hit_pct(&self) -> Option<u8> {
        if self.week_prompt_tokens == 0 {
            return None;
        }
        let pct = ((self.week_cache_read_tokens as f64) * 100.0 / (self.week_prompt_tokens as f64))
            .round()
            .clamp(0.0, 100.0) as u8;
        Some(pct)
    }
}

pub fn local_day_string(offset_days: i64) -> String {
    let dt = chrono::Local::now() - chrono::Duration::days(offset_days);
    dt.format("%Y-%m-%d").to_string()
}

impl Store {
    pub fn record_usage_delta(&self, delta: UsageDelta<'_>) -> Result<()> {
        self.record_usage_delta_on_day(&local_day_string(0), delta)
    }

    pub fn record_usage_delta_on_day(&self, day: &str, delta: UsageDelta<'_>) -> Result<()> {
        let total_tokens = delta
            .input_tokens
            .saturating_add(delta.output_tokens)
            .saturating_add(delta.cache_read_tokens)
            .saturating_add(delta.cache_write_tokens);
        let cost = if delta.cost_usd.is_finite() && delta.cost_usd > 0.0 {
            delta.cost_usd
        } else {
            0.0
        };
        if total_tokens == 0 && cost == 0.0 {
            return Ok(());
        }
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO usage_daily (
                day, scope, model, input_tokens, output_tokens,
                cache_read_tokens, cache_write_tokens, cost_usd, updated_at
             )
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(day, scope, model) DO UPDATE SET
                input_tokens = usage_daily.input_tokens + excluded.input_tokens,
                output_tokens = usage_daily.output_tokens + excluded.output_tokens,
                cache_read_tokens = usage_daily.cache_read_tokens + excluded.cache_read_tokens,
                cache_write_tokens = usage_daily.cache_write_tokens + excluded.cache_write_tokens,
                cost_usd = usage_daily.cost_usd + excluded.cost_usd,
                updated_at = excluded.updated_at",
            params![
                day,
                delta.scope,
                delta.model,
                delta.input_tokens as i64,
                delta.output_tokens as i64,
                delta.cache_read_tokens as i64,
                delta.cache_write_tokens as i64,
                cost,
                now_ms(),
            ],
        )?;
        Ok(())
    }

    pub fn query_usage_rollup(&self, scope: &str) -> Result<UsageRollup> {
        let today = local_day_string(0);
        let since = local_day_string(6);
        self.query_usage_rollup_window(scope, &today, &since)
    }

    pub fn query_usage_rollup_window(
        &self,
        scope: &str,
        today: &str,
        since_day: &str,
    ) -> Result<UsageRollup> {
        let conn = self.read_conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT day, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_usd
             FROM usage_daily
             WHERE scope = ?1 AND day >= ?2",
        )?;
        let rows = stmt.query_map(params![scope, since_day], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?.max(0) as u64,
                r.get::<_, i64>(3)?.max(0) as u64,
                r.get::<_, i64>(4)?.max(0) as u64,
                r.get::<_, i64>(5)?.max(0) as u64,
                r.get::<_, f64>(6)?.max(0.0),
            ))
        })?;

        let mut rollup = UsageRollup::default();
        let mut by_model: std::collections::BTreeMap<String, (u64, f64)> =
            std::collections::BTreeMap::new();

        for row in rows {
            let (day, model, input, output, cache_read, cache_write, cost) = row?;
            let prompt = input.saturating_add(cache_read).saturating_add(cache_write);
            let tok = prompt.saturating_add(output);
            rollup.week_tokens = rollup.week_tokens.saturating_add(tok);
            rollup.week_cost_usd += cost;
            rollup.week_prompt_tokens = rollup.week_prompt_tokens.saturating_add(prompt);
            rollup.week_cache_read_tokens =
                rollup.week_cache_read_tokens.saturating_add(cache_read);
            if day == today {
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
        Ok(rollup)
    }
}
