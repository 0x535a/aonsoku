//! Darwin-only Swift/Core ML host. Renderer calls cannot set paths or source URLs.
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    ffi::{c_char, CStr, CString},
    fs::File,
    io::{Read, Seek, SeekFrom},
    sync::Mutex,
};
use tauri::{AppHandle, Manager, WebviewWindow};

#[derive(Default)]
pub struct DynamicCoverState {
    sessions: Mutex<HashMap<String, String>>,
}

extern "C" {
    fn aonsoku_artwork_initialize(root: *const c_char, license: *const c_char);
    fn aonsoku_artwork_call(request: *const c_char) -> *mut c_char;
    fn aonsoku_artwork_free(result: *mut c_char);
}

pub fn initialize(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let root = app.path().app_data_dir()?.join("dynamic-cover");
    let license = app
        .path()
        .resource_dir()?
        .join("artwork/DepthAnythingV2-LICENSE.txt");
    let root = CString::new(root.to_string_lossy().as_bytes())?;
    let license = CString::new(license.to_string_lossy().as_bytes())?;
    unsafe { aonsoku_artwork_initialize(root.as_ptr(), license.as_ptr()) };
    Ok(())
}

/// Call only from a blocking worker. Swift never runs inference on this boundary.
fn call(operation: &str, payload: Value) -> Result<Value, String> {
    let input = CString::new(json!({ "operation": operation, "payload": payload }).to_string())
        .map_err(|_| "Invalid artwork payload")?;
    unsafe {
        let output = aonsoku_artwork_call(input.as_ptr());
        if output.is_null() {
            return Err("Artwork service unavailable".into());
        }
        let result = serde_json::from_slice::<Value>(CStr::from_ptr(output).to_bytes());
        aonsoku_artwork_free(output);
        let result = result.map_err(|_| "Invalid artwork response")?;
        if let Some(error) = result.get("error").and_then(Value::as_str) {
            return Err(error.to_string());
        }
        Ok(result)
    }
}

pub fn reset_session(app: AppHandle, label: String) {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<DynamicCoverState>();
        // Serialize resets with commands so a reload cannot grant a stale lease.
        let Ok(mut sessions) = state.sessions.lock() else {
            return;
        };
        if let Some(previous) = sessions.remove(&label) {
            let _ = call("releaseAll", json!({ "owner": previous }));
        }
        if app.get_webview_window(&label).is_some() {
            let owner = uuid::Uuid::new_v4().to_string();
            if call("openSession", json!({ "owner": owner })).is_ok() {
                sessions.insert(label, owner);
            }
        }
    });
}

pub fn close_session(app: AppHandle, label: String) {
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<DynamicCoverState>();
        if let Ok(mut sessions) = state.sessions.lock() {
            if let Some(owner) = sessions.remove(&label) {
                let _ = call("releaseAll", json!({ "owner": owner }));
            }
        };
    });
}

pub fn update_playback(artwork_url: Option<String>) {
    // Enqueue native metadata in submission order; Swift deduplicates same-cover
    // position/metadata updates and cancels obsolete original downloads.
    static FIFO: std::sync::OnceLock<std::sync::mpsc::Sender<Option<String>>> =
        std::sync::OnceLock::new();
    let sender = FIFO.get_or_init(|| {
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("artwork-metadata".into())
            .spawn(move || {
                for url in receiver {
                    let _ = call("playback", json!({ "artworkUrl": url }));
                }
            })
            .expect("artwork metadata worker");
        sender
    });
    let _ = sender.send(artwork_url);
}

#[tauri::command]
pub async fn dynamic_cover_command(
    window: WebviewWindow,
    app: AppHandle,
    operation: String,
    payload: Option<Value>,
) -> Result<Value, String> {
    if window.label() != "main" {
        return Err("Artwork is restricted to the main window".into());
    }
    if ![
        "registerDemand",
        "releaseDemand",
        "capabilities",
        "state",
        "configure",
        "download",
        "cancel",
        "remove",
        "listVideos",
        "deleteVideo",
        "clearVideos",
        "diagnostics",
        "acquire",
        "release",
    ]
    .contains(&operation.as_str())
    {
        return Err("Unsupported artwork operation".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let state = app.state::<DynamicCoverState>();
        let mut sessions = state
            .sessions
            .lock()
            .map_err(|_| "Artwork session unavailable")?;
        if !sessions.contains_key("main") {
            let owner = uuid::Uuid::new_v4().to_string();
            call("openSession", json!({ "owner": owner }))?;
            sessions.insert("main".into(), owner);
        }
        let owner = sessions.get("main").unwrap();
        let mut payload = payload.unwrap_or(json!({}));
        let object = payload.as_object_mut().ok_or("Invalid artwork payload")?;
        object.insert("owner".into(), json!(owner));
        let mut result = call(&operation, payload)?;
        if result.get("status").and_then(Value::as_str) == Some("ready") {
            let lease = result["leaseId"].as_str().ok_or("Missing artwork lease")?;
            result["src"] = json!(format!("aonsoku-artwork://localhost/{owner}/{lease}"));
        }
        Ok(result)
    })
    .await
    .map_err(|_| "Artwork worker failed")?
}

pub fn video_response(
    app: &AppHandle,
    request: tauri::http::Request<Vec<u8>>,
) -> tauri::http::Response<Vec<u8>> {
    use tauri::http::{Response, StatusCode};
    let error = |status| Response::builder().status(status).body(Vec::new()).unwrap();
    if request.method() != "GET" && request.method() != "HEAD" {
        return error(StatusCode::METHOD_NOT_ALLOWED);
    }
    let parts: Vec<_> = request
        .uri()
        .path()
        .trim_start_matches('/')
        .split('/')
        .collect();
    if parts.len() != 2
        || parts
            .iter()
            .any(|value| uuid::Uuid::parse_str(value).is_err())
    {
        return error(StatusCode::NOT_FOUND);
    }
    let state = app.state::<DynamicCoverState>();
    let Ok(sessions) = state.sessions.lock() else {
        return error(StatusCode::GONE);
    };
    if !sessions.values().any(|owner| owner == parts[0]) {
        return error(StatusCode::GONE);
    }
    let Ok(value) = call(
        "leaseFile",
        json!({ "owner": parts[0], "leaseId": parts[1] }),
    ) else {
        return error(StatusCode::GONE);
    };
    let Some(path) = value["path"].as_str() else {
        return error(StatusCode::GONE);
    };
    let Ok(mut file) = File::open(path) else {
        return error(StatusCode::NOT_FOUND);
    };
    let Ok(metadata) = file.metadata() else {
        return error(StatusCode::NOT_FOUND);
    };
    let size = metadata.len();
    if size == 0 || size > 24 * 1024 * 1024 {
        return error(StatusCode::NOT_FOUND);
    }
    let range = request
        .headers()
        .get("range")
        .and_then(|value| value.to_str().ok());
    let Some((start, end)) = byte_range(range, size) else {
        return Response::builder()
            .status(StatusCode::RANGE_NOT_SATISFIABLE)
            .header("Content-Range", format!("bytes */{size}"))
            .body(Vec::new())
            .unwrap();
    };
    let mut builder = Response::builder()
        .status(if range.is_some() {
            StatusCode::PARTIAL_CONTENT
        } else {
            StatusCode::OK
        })
        .header("Content-Type", "video/mp4")
        .header("Accept-Ranges", "bytes")
        .header("Access-Control-Allow-Origin", "*")
        .header("Cache-Control", "no-store")
        .header("Content-Length", (end - start + 1).to_string());
    if range.is_some() {
        builder = builder.header("Content-Range", format!("bytes {start}-{end}/{size}"));
    }
    let mut data = Vec::new();
    if request.method() != "HEAD" {
        if file.seek(SeekFrom::Start(start)).is_err()
            || file.take(end - start + 1).read_to_end(&mut data).is_err()
        {
            return error(StatusCode::INTERNAL_SERVER_ERROR);
        }
    }
    builder.body(data).unwrap()
}

fn byte_range(range: Option<&str>, size: u64) -> Option<(u64, u64)> {
    let Some(range) = range else {
        return Some((0, size - 1));
    };
    let (start, end) = range.strip_prefix("bytes=")?.split_once('-')?;
    if start.is_empty() {
        let suffix: u64 = end.parse().ok()?;
        return (suffix > 0).then_some((size.saturating_sub(suffix), size - 1));
    }
    let start: u64 = start.parse().ok()?;
    let end = if end.is_empty() {
        size - 1
    } else {
        end.parse::<u64>().ok()?.min(size - 1)
    };
    (start <= end && start < size).then_some((start, end))
}

#[cfg(test)]
mod tests {
    use super::byte_range;
    #[test]
    fn webkit_video_ranges() {
        assert_eq!(byte_range(Some("bytes=0-1"), 100), Some((0, 1)));
        assert_eq!(byte_range(Some("bytes=10-"), 100), Some((10, 99)));
        assert_eq!(byte_range(Some("bytes=-10"), 100), Some((90, 99)));
        assert_eq!(byte_range(Some("bytes=100-"), 100), None);
        assert_eq!(byte_range(Some("bytes=0-1,10-20"), 100), None);
    }
}
