use rust_small::{fnv1a, normalize_name, parse_items, render_summary, total_cents, Item};

fn item(name: &str, qty: u32, price_cents: u64) -> Item {
    Item {
        name: name.to_string(),
        qty,
        price_cents,
    }
}

#[test]
fn parses_a_list() {
    let items = parse_items(r#"[{"name":"tea","qty":2,"price_cents":350}]"#).unwrap();
    assert_eq!(items, vec![item("tea", 2, 350)]);
}

#[test]
fn rejects_an_empty_name() {
    let err = parse_items(r#"[{"name":"  ","qty":1,"price_cents":5}]"#).unwrap_err();
    assert!(err.to_string().contains("empty name"), "{err}");
}

#[test]
fn rejects_invalid_json() {
    let err = parse_items("[{").unwrap_err();
    assert!(err.to_string().contains("invalid item list"), "{err}");
}

#[test]
fn totals_quantity_times_price() {
    let items = [item("a", 2, 150), item("b", 3, 100)];
    assert_eq!(total_cents(&items), 600);
}

#[test]
fn empty_total_is_zero() {
    assert_eq!(total_cents(&[]), 0);
}

#[test]
fn normalizes_names() {
    assert_eq!(normalize_name("  Black   TEA "), "black tea");
}

#[test]
fn fnv1a_of_nothing_is_the_offset_basis() {
    assert_eq!(fnv1a(b""), 0xcbf2_9ce4_8422_2325);
}

#[test]
fn fnv1a_of_a_known_input() {
    assert_eq!(fnv1a(b"a"), 0xaf63_dc4c_8601_ec8c);
}

#[test]
fn renders_a_summary() {
    let items = [item("a", 2, 1250)];
    assert_eq!(render_summary(&items), "1 items, total 25.00");
}
