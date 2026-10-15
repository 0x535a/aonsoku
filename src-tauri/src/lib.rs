mod desktop_audio;
mod desktop_cache;
#[cfg(target_os = "macos")]
mod dynamic_cover;
#[cfg(target_os = "macos")]
mod macos;
mod media;
#[cfg(target_os = "macos")]
use tauri::Manager;

pub fn run() {
    let builder = tauri::Builder::default()
        .manage(desktop_audio::DesktopAudioState::default())
        .manage(media::MediaControlsState::default());
    #[cfg(target_os = "macos")]
    let builder = builder
        .manage(dynamic_cover::DynamicCoverState::default())
        .setup(|app| dynamic_cover::initialize(app.handle()))
        .on_page_load(|webview, payload| {
            if payload.event() == tauri::webview::PageLoadEvent::Started {
                dynamic_cover::reset_session(
                    webview.app_handle().clone(),
                    webview.label().to_string(),
                );
            }
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::Destroyed) {
                dynamic_cover::close_session(
                    window.app_handle().clone(),
                    window.label().to_string(),
                );
            }
        })
        .register_asynchronous_uri_scheme_protocol(
            "aonsoku-artwork",
            |context, request, responder| {
                let app = context.app_handle().clone();
                tauri::async_runtime::spawn_blocking(move || {
                    responder.respond(dynamic_cover::video_response(&app, request));
                });
            },
        );
    builder
        .invoke_handler(tauri::generate_handler![
            #[cfg(target_os = "macos")]
            dynamic_cover::dynamic_cover_command,
            desktop_audio::desktop_audio_load,
            desktop_audio::desktop_audio_play,
            desktop_audio::desktop_audio_pause,
            desktop_audio::desktop_audio_stop,
            desktop_audio::desktop_audio_seek,
            desktop_audio::desktop_audio_set_volume,
            desktop_audio::desktop_audio_update_metadata,
            desktop_audio::desktop_audio_set_repeat_mode,
            desktop_audio::desktop_audio_set_shuffle,
            desktop_cache::desktop_cache_store_audio_file,
            desktop_cache::desktop_cache_resolve_audio_file,
            desktop_cache::desktop_cache_get_audio_file_size,
            desktop_cache::desktop_cache_delete_audio_file,
            desktop_cache::desktop_cache_clear_audio_files,
            media::media_update_session,
            media::media_update_position,
            media::media_clear_session,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Aonsoku Tauri application");
}
