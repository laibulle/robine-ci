use chrono::{TimeZone, Utc};

fn at(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(year, month, day, hour, minute, 0)
        .single()
        .expect("test timestamp is valid")
}

#[test]
fn matches_wildcards_lists_ranges_and_steps() {
    let monday = at(2026, 8, 17, 10, 30);
    assert!(robine_workflows::cron_matches("* * * * *", monday));
    assert!(robine_workflows::cron_matches("0,30 9-17 * * 1-5", monday));
    assert!(robine_workflows::cron_matches("*/15 10 * * 1", monday));
    assert!(!robine_workflows::cron_matches("*/20 10 * * 1", monday));
    assert!(!robine_workflows::cron_matches("30 11 * * 1", monday));
}

#[test]
fn normalizes_sunday_and_uses_day_field_or_semantics() {
    let sunday = at(2026, 8, 16, 2, 0);
    assert!(robine_workflows::cron_matches("0 2 * * 0", sunday));
    assert!(robine_workflows::cron_matches("0 2 * * 7", sunday));

    let monday_the_seventeenth = at(2026, 8, 17, 2, 0);
    assert!(robine_workflows::cron_matches(
        "0 2 17 * 2",
        monday_the_seventeenth
    ));
    assert!(robine_workflows::cron_matches(
        "0 2 18 * 1",
        monday_the_seventeenth
    ));
    assert!(!robine_workflows::cron_matches(
        "0 2 18 * 2",
        monday_the_seventeenth
    ));
}

#[test]
fn invalid_expressions_never_match() {
    let minute = at(2026, 8, 17, 10, 30);
    assert!(!robine_workflows::cron_matches("@daily", minute));
    assert!(!robine_workflows::cron_matches("*/0 * * * *", minute));
    assert!(!robine_workflows::cron_matches("60 * * * *", minute));
}
