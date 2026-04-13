use std::sync::{Arc, OnceLock};
use axum::Router;
use tower::ServiceBuilder;
use vercel_runtime::Error;
use vercel_runtime::axum::VercelLayer;

static STATE: OnceLock<Arc<rex_serve::state::AppState>> = OnceLock::new();

fn get_state() -> Arc<rex_serve::state::AppState> {
    STATE.get_or_init(|| {
        tracing_subscriber::fmt::init();

        // On Vercel, function files are in /var/task
        let project_root = std::env::current_dir()
            .expect("cannot determine working directory");

        eprintln!("rex-serve init: project_root={}", project_root.display());
        if let Ok(entries) = std::fs::read_dir(&project_root) {
            for entry in entries.flatten() {
                eprintln!("  {}", entry.path().display());
            }
        }

        let config = rex_serve::config::Config::load(&project_root);

        rex_serve::state::AppState::build(config, project_root)
            .expect("failed to initialize rex-serve state")
    }).clone()
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    let state = get_state();

    let router = Router::new()
        .fallback(rex_serve::handler::handle_request)
        .with_state(state);

    let app = ServiceBuilder::new()
        .layer(VercelLayer::new())
        .service(router);

    vercel_runtime::run(app).await
}
