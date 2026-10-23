//! macOS screen capture and display management backend for xChup / Snip.

pub mod clipboard;

use std::sync::Arc;
use core_graphics::display::CGDisplay;
use core_graphics::image::CGImage;
use snip_core::frame::{Frame, PixelFormat, ShmBuf};
use snip_core::geometry::{Rect, Transform};

#[derive(Clone, Debug, PartialEq)]
pub struct DisplayInfo {
    pub id: u32,
    pub name: String,
    pub logical: Rect,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub scale: f64,
}

#[derive(Clone, Debug)]
pub struct WindowInfo {
    pub id: u32,
    pub owner_name: String,
    pub title: String,
    pub bounds: Rect,
}

/// Enumerate all active displays on macOS.
pub fn get_displays() -> Vec<DisplayInfo> {
    let active_ids = CGDisplay::active_displays().unwrap_or_default();
    active_ids
        .into_iter()
        .map(|id| {
            let display = CGDisplay::new(id);
            let bounds = display.bounds();
            let pixel_w = display.pixels_wide() as u32;
            let pixel_h = display.pixels_high() as u32;
            let scale = if bounds.size.width > 0.0 {
                pixel_w as f64 / bounds.size.width
            } else {
                1.0
            };
            DisplayInfo {
                id,
                name: format!("Display {}", id),
                logical: Rect::new(
                    bounds.origin.x as i32,
                    bounds.origin.y as i32,
                    bounds.size.width as i32,
                    bounds.size.height as i32,
                ),
                pixel_width: pixel_w,
                pixel_height: pixel_h,
                scale,
            }
        })
        .collect()
}

/// Capture a single display into a Snip Frame backed by ShmBuf.
pub fn capture_display(id: u32) -> Result<Frame, String> {
    let display = CGDisplay::new(id);
    let cg_image = display
        .image()
        .ok_or_else(|| format!("failed to capture display {}", id))?;

    let bounds = display.bounds();
    let logical = Rect::new(
        bounds.origin.x as i32,
        bounds.origin.y as i32,
        bounds.size.width as i32,
        bounds.size.height as i32,
    );
    let scale = if bounds.size.width > 0.0 {
        cg_image.width() as f64 / bounds.size.width
    } else {
        1.0
    };

    let frame = cg_image_to_frame(
        cg_image,
        format!("Display-{}", id),
        logical,
        scale,
    )?;
    Ok(frame)
}

/// Capture all active displays on macOS.
pub fn capture_all() -> Result<Vec<Frame>, String> {
    let displays = get_displays();
    let mut frames = Vec::with_capacity(displays.len());
    for d in displays {
        let frame = capture_display(d.id)?;
        frames.push(frame);
    }
    Ok(frames)
}

/// Convert a macOS CGImage into a `snip_core::frame::Frame` backed by `ShmBuf`.
pub fn cg_image_to_frame(
    image: CGImage,
    output_name: String,
    logical: Rect,
    scale: f64,
) -> Result<Frame, String> {
    let width = image.width() as u32;
    let height = image.height() as u32;
    let bytes_per_row = image.bytes_per_row() as usize;

    let data = image.data();
    let src_bytes = data.bytes();

    let mut buf = ShmBuf::new(width, height, PixelFormat::Xrgb8888)
        .map_err(|e| format!("failed to create shm buffer: {e}"))?;

    let dst_bytes = buf.bytes_mut();
    let target_stride = (width * 4) as usize;

    if bytes_per_row == target_stride {
        let copy_len = (target_stride * height as usize).min(src_bytes.len()).min(dst_bytes.len());
        dst_bytes[..copy_len].copy_from_slice(&src_bytes[..copy_len]);
    } else {
        // Handle row padding from CoreGraphics
        for y in 0..height as usize {
            let src_start = y * bytes_per_row;
            let src_end = src_start + target_stride;
            let dst_start = y * target_stride;
            let dst_end = dst_start + target_stride;

            if src_end <= src_bytes.len() && dst_end <= dst_bytes.len() {
                dst_bytes[dst_start..dst_end].copy_from_slice(&src_bytes[src_start..src_end]);
            }
        }
    }

    Ok(Frame {
        output: output_name,
        buf: Arc::new(buf),
        transform: Transform::Normal,
        scale,
        logical,
        epoch: 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn can_enumerate_displays() {
        let displays = get_displays();
        assert!(!displays.is_empty(), "expected at least one active display");
        for d in displays {
            assert!(d.pixel_width > 0);
            assert!(d.pixel_height > 0);
            assert!(d.scale > 0.0);
        }
    }

    #[test]
    fn can_capture_primary_display() {
        let displays = get_displays();
        if let Some(main) = displays.first() {
            if let Ok(frame) = capture_display(main.id) {
                assert!(frame.buf.width > 0);
                assert!(frame.buf.height > 0);
                assert!(!frame.buf.is_empty());

                // Test encoding this real captured frame using snip-core's fdeflate PNG encoder!
                let rect = Rect::new(0, 0, 100.min(frame.buf.width as i32), 100.min(frame.buf.height as i32));
                let encoded = snip_core::encode::crop_and_encode(&frame, rect);
                assert!(!encoded.png.is_empty(), "PNG bytes should not be empty");
                assert_eq!(&encoded.png[0..8], &[137, 80, 78, 71, 13, 10, 26, 10], "Valid PNG signature");
                println!(
                    "Captured macOS display {}: {}x{} px (scale {:.1}) -> crop 100x100 took {:.2}ms, encode took {:.2}ms (PNG size: {} bytes)",
                    main.id, frame.buf.width, frame.buf.height, frame.scale, encoded.crop_ms, encoded.encode_ms, encoded.png.len()
                );
            }
        }
    }
}

