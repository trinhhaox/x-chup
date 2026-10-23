//! snipd: Background daemon for macOS.
//!
//! Listens on $XDG_RUNTIME_DIR/snip/ctl.sock for requests from `snip` CLI
//! and native macOS UI overlays.

use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::json;
use snip_core::geometry::Rect;
use snip_core::history::{History, Record};
use snip_core::paths;
use snip_ipc::{Request, Response};

fn find_ui_bin() -> PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            let xchup = parent.join("xChup");
            if xchup.exists() {
                return xchup;
            }
            let sibling = parent.join("snip-ui");
            if sibling.exists() {
                return sibling;
            }
        }
    }
    let app_bin = PathBuf::from("/Applications/xChup.app/Contents/MacOS/xChup");
    if app_bin.exists() {
        return app_bin;
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let local_ui = PathBuf::from(format!("{home}/.local/bin/snip-ui"));
    if local_ui.exists() {
        return local_ui;
    }
    PathBuf::from("target/debug/snip-ui")
}

fn get_png_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.len() >= 24 && &bytes[0..8] == b"\x89PNG\r\n\x1a\n" && &bytes[12..16] == b"IHDR" {
        let width = u32::from_be_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]);
        let height = u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]);
        Some((width, height))
    } else {
        None
    }
}

struct RecordingState {
    child: std::process::Child,
    path: PathBuf,
    is_gif: bool,
}

static RECORDING: std::sync::Mutex<Option<RecordingState>> = std::sync::Mutex::new(None);

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();

    // Ensure private runtime directory exists for the socket
    let runtime_dir = paths::runtime_dir();
    paths::ensure_private_dir(&runtime_dir)?;
    let socket_path = paths::ctl_socket();

    println!("Starting snipd (macOS)...");
    println!("Socket path: {}", socket_path.display());

    let quit_signal = running.clone();
    let sock_val = socket_path.clone();

    snip_ipc::serve(move |req| {
        match req {
            Request::Ping => Response::ok(json!("pong")),

            Request::Status => {
                let displays = snip_darwin::get_displays();
                Response::ok(json!({
                    "platform": "darwin",
                    "status": "running",
                    "displays": displays.len(),
                    "socket": sock_val.to_string_lossy(),
                }))
            }

            Request::Capture {
                mode,
                rect,
                action,
                delay,
                ..
            } => {
                if let Some(d) = delay {
                    if d > 0 {
                        std::thread::sleep(Duration::from_secs(d as u64));
                    }
                }

                let id = ulid::Ulid::new().to_string();
                let save_dir = paths::default_screenshot_dir();
                let _ = fs::create_dir_all(&save_dir);
                let now = chrono::Local::now();
                let filename = format!("Capture-{}.png", now.format("%Y-%m-%d-%H%M%S"));
                let file_path = save_dir.join(&filename);
                let file_str = file_path.to_string_lossy().to_string();
                let ui_bin = find_ui_bin();

                // Chụp màn hình bằng /usr/sbin/screencapture để lấy ảnh Retina thực sự từ WindowServer
                if let Some([x, y, w, h]) = rect {
                    let r_arg = format!("-R{x},{y},{w},{h}");
                    let output = Command::new("/usr/sbin/screencapture")
                        .arg("-x")
                        .arg(&r_arg)
                        .arg(&file_path)
                        .output();
                    match output {
                        Ok(out) if out.status.success() => {},
                        Ok(out) => return Response::err(format!("screencapture failed: {}", String::from_utf8_lossy(&out.stderr))),
                        Err(e) => return Response::err(format!("failed to execute screencapture: {e}")),
                    }
                } else if mode == "area" || mode.starts_with("text") {
                    let output = Command::new(&ui_bin).arg("overlay").arg(&file_path).output();
                    match output {
                        Ok(out) if out.status.success() => {},
                        Ok(out) => {
                            let err_str = String::from_utf8_lossy(&out.stderr).trim().to_string();
                            if err_str.contains("Cancelled") {
                                return Response::err("selection cancelled");
                            } else {
                                return Response::err(format!("overlay capture failed: {err_str}"));
                            }
                        }
                        Err(e) => return Response::err(format!("failed to spawn overlay: {e}")),
                    }
                } else {
                    // Fullscreen capture qua xChup UI
                    let output = Command::new(&ui_bin).arg("fullscreen").arg(&file_path).output();
                    match output {
                        Ok(out) if out.status.success() => {},
                        Ok(out) => return Response::err(format!("ui fullscreen failed (status {}): stdout='{}', stderr='{}'", out.status, String::from_utf8_lossy(&out.stdout).trim(), String::from_utf8_lossy(&out.stderr).trim())),
                        Err(e) => return Response::err(format!("failed to spawn ui binary {}: {e}", ui_bin.display())),
                    }
                }

                let file_bytes = match fs::read(&file_path) {
                    Ok(b) => b,
                    Err(e) => return Response::err(format!("failed to read capture: {e}")),
                };
                let (width, height) = get_png_dimensions(&file_bytes).unwrap_or((0, 0));
                let file_len = file_bytes.len();

                let is_text_mode = mode.starts_with("text");
                let mut ocr_text = String::new();

                if is_text_mode {
                    let output = Command::new(&ui_bin).arg("ocr").arg(&file_path).output();
                    if let Ok(out) = output {
                        ocr_text = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    }
                } else {
                    let should_copy = match action.as_deref() {
                        Some("copy") | None => true,
                        _ => false,
                    };

                    if should_copy {
                        if let Err(e) = snip_darwin::clipboard::copy_png_to_clipboard(&file_path) {
                            eprintln!("Warning: failed to copy to clipboard: {e}");
                        }
                    }
                }

                // Add to history database
                let history_dir = paths::history_dir();
                let _ = fs::create_dir_all(&history_dir);
                if let Ok(hist) = History::open(&history_dir) {
                    let record = Record {
                        id: id.clone(),
                        created_at: now.timestamp(),
                        kind: if is_text_mode { "text".into() } else { "screenshot".into() },
                        width,
                        height,
                        scale: 2.0,
                        output: "main".into(),
                        source: file_path.clone(),
                        saved: Some(file_path.clone()),
                        app: None,
                        title: None,
                        duration_ms: 0,
                    };
                    let _ = hist.insert(&record);
                    if !ocr_text.is_empty() {
                        let _ = hist.set_index(&id, &ocr_text);
                    }
                }

                // Show Quick Access Card thumbnail if not pure text mode
                if !is_text_mode {
                    let _ = Command::new(&ui_bin).arg("card").arg(&file_str).spawn();
                }

                Response::ok(json!({
                    "id": id,
                    "mode": mode,
                    "path": file_str,
                    "width": width,
                    "height": height,
                    "crop_ms": 0,
                    "encode_ms": 0,
                    "bytes": file_len,
                    "copied_to_clipboard": true,
                    "text": if is_text_mode { Some(ocr_text) } else { None },
                }))
            }

            Request::Pin { id, path } => {
                let target_path = if let Some(p) = path {
                    PathBuf::from(p)
                } else {
                    let history_dir = paths::history_dir();
                    if let Ok(hist) = History::open(&history_dir) {
                        let target_record = match id {
                            Some(ref req_id) => hist.get(req_id),
                            None => hist.recent(1).map(|items| items.into_iter().next()),
                        };
                        match target_record {
                            Ok(Some(item)) => item.source,
                            _ => return Response::err("capture not found in history"),
                        }
                    } else {
                        return Response::err("could not open history");
                    }
                };

                let ui_bin = find_ui_bin();
                let path_str = target_path.to_string_lossy().to_string();
                let _ = Command::new(ui_bin).arg("pin").arg(&path_str).spawn();

                Response::ok(json!({ "pinned": path_str }))
            }

            Request::ReadText { path } => {
                let target_path = if let Some(p) = path {
                    PathBuf::from(p)
                } else {
                    let history_dir = paths::history_dir();
                    if let Ok(hist) = History::open(&history_dir) {
                        let target_record = hist.recent(1).map(|items| items.into_iter().next());
                        match target_record {
                            Ok(Some(item)) => item.source,
                            _ => return Response::err("no recent capture found in history"),
                        }
                    } else {
                        return Response::err("could not open history");
                    }
                };

                let ui_bin = find_ui_bin();
                let output = Command::new(ui_bin)
                    .arg("ocr")
                    .arg(&target_path)
                    .output();

                match output {
                    Ok(out) if out.status.success() => {
                        let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
                        Response::ok(json!({ "text": text, "file": target_path.to_string_lossy() }))
                    }
                    Ok(out) => Response::err(String::from_utf8_lossy(&out.stderr).trim().to_string()),
                    Err(e) => Response::err(format!("failed to run ocr: {e}")),
                }
            }

            Request::Copy { id } => {
                let history_dir = paths::history_dir();
                if let Ok(hist) = History::open(&history_dir) {
                    let target_record = match id {
                        Some(ref req_id) => hist.get(req_id),
                        None => hist.recent(1).map(|items| items.into_iter().next()),
                    };
                    if let Ok(Some(item)) = target_record {
                        let path = std::path::Path::new(&item.source);
                        if let Err(e) = snip_darwin::clipboard::copy_png_to_clipboard(path) {
                            return Response::err(format!("failed to copy: {e}"));
                        }
                        return Response::ok(json!({ "copied": item.source.to_string_lossy() }));
                    }
                }
                Response::err("capture not found in history")
            }

            Request::List { n } => {
                let history_dir = paths::history_dir();
                if let Ok(hist) = History::open(&history_dir) {
                    if let Ok(items) = hist.recent(n) {
                        return Response::ok(json!(items));
                    }
                }
                Response::ok(json!([]))
            }

            Request::Open { path } => {
                let p = PathBuf::from(&path);
                if p.exists() {
                    let ui_bin = find_ui_bin();
                    let _ = Command::new(ui_bin).arg("card").arg(&path).spawn();
                    Response::ok(json!({ "opened": path }))
                } else {
                    Response::err(format!("file not found: {path}"))
                }
            }

            Request::Desktop { action } => {
                let hide = match action.as_str() {
                    "hide" => true,
                    "show" => false,
                    _ => {
                        let cur = Command::new("defaults")
                            .args(["read", "com.apple.finder", "CreateDesktop"])
                            .output();
                        if let Ok(out) = cur {
                            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
                            s != "false" && s != "0"
                        } else {
                            true
                        }
                    }
                };

                let val_str = if hide { "false" } else { "true" };
                let _ = Command::new("defaults")
                    .args(["write", "com.apple.finder", "CreateDesktop", "-bool", val_str])
                    .status();
                let _ = Command::new("killall").arg("Finder").status();
                Response::ok(json!({ "desktop_icons_hidden": hide }))
            }

            Request::History => {
                let captures_dir = paths::data_dir().join("captures");
                let _ = Command::new("open").arg(&captures_dir).spawn();
                Response::ok(json!({ "history_dir": captures_dir.to_string_lossy() }))
            }

            Request::Record { action, gif, rect, whole, .. } => {
                let mut rec_lock = RECORDING.lock().unwrap();
                match action.as_str() {
                    "status" => {
                        Response::ok(json!({
                            "recording": rec_lock.is_some(),
                            "path": rec_lock.as_ref().map(|r| r.path.to_string_lossy())
                        }))
                    }
                    "stop" => {
                        if let Some(mut state) = rec_lock.take() {
                            let pid = state.child.id() as i32;
                            unsafe { libc::kill(pid, libc::SIGINT); }
                            let _ = state.child.wait();

                            let mut final_path = state.path;
                            if state.is_gif {
                                let gif_path = final_path.with_extension("gif");
                                let ffmpeg_res = Command::new("ffmpeg")
                                    .args(["-y", "-i", &final_path.to_string_lossy(), "-vf", "fps=15,scale=flags=lanczos", &gif_path.to_string_lossy()])
                                    .status();
                                if let Ok(st) = ffmpeg_res {
                                    if st.success() {
                                        let _ = fs::remove_file(&final_path);
                                        final_path = gif_path;
                                    }
                                }
                            }

                            let ui_bin = find_ui_bin();
                            let _ = Command::new(ui_bin).arg("card").arg(&final_path).spawn();
                            Response::ok(json!({ "stopped": true, "path": final_path.to_string_lossy() }))
                        } else {
                            Response::err("no recording in progress")
                        }
                    }
                    "start" | "toggle" => {
                        if rec_lock.is_some() {
                            if let Some(mut state) = rec_lock.take() {
                                let pid = state.child.id() as i32;
                                unsafe { libc::kill(pid, libc::SIGINT); }
                                let _ = state.child.wait();

                                let mut final_path = state.path;
                                if state.is_gif {
                                    let gif_path = final_path.with_extension("gif");
                                    let ffmpeg_res = Command::new("ffmpeg")
                                        .args(["-y", "-i", &final_path.to_string_lossy(), "-vf", "fps=15,scale=flags=lanczos", &gif_path.to_string_lossy()])
                                        .status();
                                    if let Ok(st) = ffmpeg_res {
                                        if st.success() {
                                            let _ = fs::remove_file(&final_path);
                                            final_path = gif_path;
                                        }
                                    }
                                }

                                let ui_bin = find_ui_bin();
                                let _ = Command::new(ui_bin).arg("card").arg(&final_path).spawn();
                                return Response::ok(json!({ "stopped": true, "path": final_path.to_string_lossy() }));
                            }
                        }

                        let captures_dir = paths::data_dir().join("captures");
                        let _ = paths::ensure_private_dir(&captures_dir);
                        let now = chrono::Local::now();
                        let filename = format!("snip_rec_{}.mov", now.format("%Y%m%d-%H%M%S"));
                        let file_path = captures_dir.join(filename);

                        let mut cmd = Command::new("/usr/sbin/screencapture");
                        cmd.arg("-v");

                        if !whole {
                            let crop_rect = match rect {
                                Some([x, y, w, h]) => Some(Rect::new(x, y, w, h)),
                                None => {
                                    let ui_bin = find_ui_bin();
                                    let output = Command::new(ui_bin).arg("overlay").output();
                                    match output {
                                        Ok(out) if out.status.success() => {
                                            let out_str = String::from_utf8_lossy(&out.stdout);
                                            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&out_str) {
                                                let x = v["x"].as_i64().unwrap_or(0) as i32;
                                                let y = v["y"].as_i64().unwrap_or(0) as i32;
                                                let w = v["w"].as_i64().unwrap_or(100) as i32;
                                                let h = v["h"].as_i64().unwrap_or(100) as i32;
                                                Some(Rect::new(x, y, w, h))
                                            } else {
                                                None
                                            }
                                        }
                                        _ => return Response::err("area selection cancelled"),
                                    }
                                }
                            };

                            if let Some(r) = crop_rect {
                                cmd.arg("-R").arg(format!("{},{},{},{}", r.x, r.y, r.w, r.h));
                            }
                        }

                        cmd.arg(&file_path);
                        match cmd.spawn() {
                            Ok(child) => {
                                *rec_lock = Some(RecordingState {
                                    child,
                                    path: file_path.clone(),
                                    is_gif: gif,
                                });
                                Response::ok(json!({ "recording": true, "path": file_path.to_string_lossy() }))
                            }
                            Err(e) => Response::err(format!("failed to start screen recording: {e}")),
                        }
                    }
                    other_act => Response::err(format!("recording action '{other_act}' not supported")),
                }
            }

            Request::Quit => {
                quit_signal.store(false, Ordering::SeqCst);
                Response::ok(json!("quitting"))
            }

            other => Response::err(format!("command not yet supported on macOS: {:?}", other)),
        }
    })?;

    println!("snipd is running. Press Ctrl+C to stop.");
    while r.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(200));
    }

    let _ = fs::remove_file(&socket_path);
    println!("snipd stopped.");
    Ok(())
}
