use robine_persistence::{Database, Readiness};

#[tokio::test]
async fn reads_the_existing_ecto_schema_when_configured() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };

    let database = Database::connect(&database_url, 2)
        .await
        .expect("connect to the migrated Robine database");

    database.ready().await.expect("database is ready");
    database
        .list_pipelines("standalone", 10)
        .await
        .expect("read pipelines through the existing schema and tenant policy");
}
