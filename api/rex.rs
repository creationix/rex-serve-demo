use std::sync::{Arc, OnceLock};
use axum::Router;
use tower::ServiceBuilder;
use vercel_runtime::Error;
use vercel_runtime::axum::VercelLayer;
use include_dir::{include_dir, Dir};

// Embed all project files at compile time
static ROUTES_DIR: Dir = include_dir!("$CARGO_MANIFEST_DIR/routes");
static REXD_SOURCE: &str = include_str!("../rex-serve.rexd");
static TOML_SOURCE: &str = include_str!("../rex-serve.toml");

static STATE: OnceLock<Arc<rex_serve::state::AppState>> = OnceLock::new();

/// Extract embedded files to /tmp/rex-project/ so rex-serve can read them
fn extract_embedded_files() -> std::path::PathBuf {
    let root = std::path::PathBuf::from("/tmp/rex-project");
    let routes_dir = root.join("routes");

    // Skip if already extracted (warm invocation)
    if routes_dir.exists() {
        return root;
    }

    std::fs::create_dir_all(&routes_dir).expect("create routes dir");

    // Extract route files recursively
    extract_dir(&ROUTES_DIR, &routes_dir);

    // Write config files
    std::fs::write(root.join("rex-serve.rexd"), REXD_SOURCE).expect("write rexd");
    std::fs::write(root.join("rex-serve.toml"), TOML_SOURCE).expect("write toml");

    root
}

fn extract_dir(dir: &Dir, target: &std::path::Path) {
    for file in dir.files() {
        let dest = target.join(file.path().file_name().unwrap());
        std::fs::write(&dest, file.contents()).expect("write file");
    }
    for sub in dir.dirs() {
        let sub_target = target.join(sub.path().file_name().unwrap());
        std::fs::create_dir_all(&sub_target).expect("create subdir");
        extract_dir(sub, &sub_target);
    }
}

fn get_state() -> Arc<rex_serve::state::AppState> {
    STATE.get_or_init(|| {
        tracing_subscriber::fmt::init();

        let project_root = extract_embedded_files();
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
