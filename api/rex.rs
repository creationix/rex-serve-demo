use std::sync::{Arc, OnceLock};
use axum::{Router, routing::get, response::IntoResponse};
use tower::ServiceBuilder;
use vercel_runtime::Error;
use vercel_runtime::axum::VercelLayer;

static STATE: OnceLock<Arc<rex_serve::state::AppState>> = OnceLock::new();
static INIT_LOG: OnceLock<String> = OnceLock::new();

fn get_state() -> Arc<rex_serve::state::AppState> {
    STATE.get_or_init(|| {
        tracing_subscriber::fmt::init();

        let project_root = std::env::current_dir()
            .expect("cannot determine working directory");

        fn list_recursive(path: &std::path::Path, depth: usize) -> String {
            let mut out = String::new();
            if let Ok(entries) = std::fs::read_dir(path) {
                for entry in entries.flatten() {
                    let p = entry.path();
                    let indent = "  ".repeat(depth);
                    let name = p.file_name().unwrap_or_default().to_string_lossy();
                    if p.is_dir() {
                        out.push_str(&format!("{indent}{name}/\n"));
                        if depth < 3 { out.push_str(&list_recursive(&p, depth + 1)); }
                    } else {
                        out.push_str(&format!("{indent}{name}\n"));
                    }
                }
            }
            out
        }
        let tree = list_recursive(&project_root, 0);
        INIT_LOG.get_or_init(|| format!("cwd: {}\n\n{tree}", project_root.display()));

        let config = rex_serve::config::Config::load(&project_root);

        match rex_serve::state::AppState::build(config, project_root) {
            Ok(state) => state,
            Err(e) => panic!("init failed: {e}\nFiles:\n{tree}"),
        }
    }).clone()
}

async fn debug_handler() -> impl IntoResponse {
    let log = INIT_LOG.get().map(|s| s.as_str()).unwrap_or("not initialized");
    ([("content-type", "text/plain")], log.to_string())
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    let state = get_state();

    let router = Router::new()
        .route("/__debug", get(debug_handler))
        .fallback(rex_serve::handler::handle_request)
        .with_state(state);

    let app = ServiceBuilder::new()
        .layer(VercelLayer::new())
        .service(router);

    vercel_runtime::run(app).await
}
