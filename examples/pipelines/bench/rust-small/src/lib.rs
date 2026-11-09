//! Small helpers for the bench: a record type, parsing, totals, and a checksum.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub name: String,
    pub qty: u32,
    pub price_cents: u64,
}

/// Parses a JSON list of items; an item with an empty name is an error.
pub fn parse_items(json: &str) -> Result<Vec<Item>> {
    let items: Vec<Item> = serde_json::from_str(json).context("invalid item list")?;
    if let Some(bad) = items.iter().find(|i| i.name.trim().is_empty()) {
        bail!("item with empty name (qty {})", bad.qty);
    }
    Ok(items)
}

/// Sum of quantity times price, in cents.
pub fn total_cents(items: &[Item]) -> u64 {
    items.iter().map(|i| i.price_cents * u64::from(i.qty)).sum()
}

/// Collapses runs of whitespace and lowercases.
pub fn normalize_name(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// FNV-1a, 64 bit.
pub fn fnv1a(data: &[u8]) -> u64 {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    data.iter()
        .fold(OFFSET, |h, b| (h ^ u64::from(*b)).wrapping_mul(PRIME))
}

/// One line for a list of items, e.g. `2 items, total 12.50`.
pub fn render_summary(items: &[Item]) -> String {
    let total = total_cents(items);
    format!("{} items, total {}.{:02}", items.len(), total / 100, total % 100)
}
