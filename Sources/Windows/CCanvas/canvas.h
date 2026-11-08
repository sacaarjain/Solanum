// A small C interface over Direct2D and DirectWrite. DirectWrite's headers are C++ only, so Swift can't call it directly.
// Coordinates are physical pixels. Colors are 0xRRGGBB.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SolCanvas SolCanvas;

enum {
    SOL_STYLE_BOLD = 1,
    SOL_STYLE_ITALIC = 2,
};

typedef struct {
    float cellWidth;
    float cellHeight;
    /// From the top of a cell.
    float baseline;
    float underlineY;
    float strikeY;
    float lineThickness;
} SolMetrics;

void sol_enable_dpi_awareness(void);
void sol_use_dark_titlebar(void *hwnd);
/// Lets the desktop show through where the window is see-through (`transparent`), blurred by Windows 11's acrylic when
/// `blur`; or makes it solid again.
void sol_window_set_backdrop(void *hwnd, int32_t transparent, int32_t blur);

/// On failure these return NULL and set `hr`.
SolCanvas *sol_canvas_create_window(void *hwnd, float fontPixels, int32_t *hr);
SolCanvas *sol_canvas_create_bitmap(int32_t width, int32_t height, float fontPixels, int32_t *hr);
void sol_canvas_destroy(SolCanvas *canvas);

SolMetrics sol_canvas_metrics(SolCanvas *canvas);
int32_t sol_canvas_set_font_pixels(SolCanvas *canvas, float fontPixels);
/// A family to try before the defaults (NUL-terminated UTF-16, empty for none), its size, and the line height as a
/// multiple of the size (0 for the font's own).
int32_t sol_canvas_set_font(SolCanvas *canvas, const uint16_t *family, float fontPixels, float lineHeight);
void sol_canvas_resize(SolCanvas *canvas, int32_t width, int32_t height);

/// Returns a negative HRESULT when nothing can be drawn right now; don't draw or call `end` then.
int32_t sol_canvas_begin(SolCanvas *canvas, uint32_t background);
int32_t sol_canvas_end(SolCanvas *canvas);

void sol_canvas_fill_rect(SolCanvas *canvas, float x, float y, float width, float height, uint32_t color, float alpha);
void sol_canvas_stroke_rect(SolCanvas *canvas, float x, float y, float width, float height, uint32_t color, float thickness);

/// Draws characters into consecutive cells starting at (x, y), the top left of the first. `widths` says how many cells
/// each takes, so columns stay exact whatever the font's own advances. Characters the font lacks use system fallback.
void sol_canvas_draw_cells(SolCanvas *canvas, float x, float y, const uint32_t *scalars, const uint8_t *widths,
                           int32_t count, uint32_t color, int32_t style);

/// Draws text shaped as a whole (a character and its combining marks) in `cells` cells.
void sol_canvas_draw_text(SolCanvas *canvas, float x, float y, int32_t cells, const uint16_t *text, int32_t length,
                          uint32_t color, int32_t style);

// Interface drawing, antialiased, as opposed to the terminal's exact cells.
void sol_canvas_fill_gradient(SolCanvas *canvas, float x, float y, float width, float height, uint32_t top, uint32_t bottom);
/// How opaque the window's own backgrounds are: the clear color, gradients and backdrop fills. Below 1, the window
/// target keeps alpha so the desktop shows through.
void sol_canvas_set_opacity(SolCanvas *canvas, float opacity);
/// A background of the window's own (a bar, a sidebar, a page) at that opacity, replacing what's under it so it's no
/// more solid where it's drawn over another.
void sol_canvas_backdrop_rect(SolCanvas *canvas, float x, float y, float width, float height, uint32_t color);
void sol_canvas_backdrop_rounded(SolCanvas *canvas, float x, float y, float width, float height, float radius, uint32_t color);
/// The desktop wallpaper drawn under the window's see-through backgrounds, so it shows through them rather than the
/// windows behind: `path` (null for just `background`) placed on a monitor of `width` by `height` pixels as Windows
/// places it (`position`, a DESKTOP_WALLPAPER_POSITION), blurred by `blur` pixels. A null path and a background of
/// 0xFFFFFFFF take it away. Negative if the picture couldn't be read (the background color is used).
int32_t sol_canvas_set_wallpaper(SolCanvas *canvas, const uint16_t *path, int32_t width, int32_t height, int32_t position,
                                 uint32_t background, float blur);
/// Where the wallpaper's monitor's top left is in the window, in pixels: changes as the window moves.
void sol_canvas_set_wallpaper_origin(SolCanvas *canvas, float x, float y);
/// Drawn `zoom` times the size it was made for: a theme's picture filling the window.
void sol_canvas_set_wallpaper_zoom(SolCanvas *canvas, float zoom);
/// A picture file's size in pixels, without reading all of it. Negative if it isn't one.
int32_t sol_image_file_size(SolCanvas *canvas, const uint16_t *path, int32_t *width, int32_t *height);
/// A picture file as an image to draw, no bigger than `maxSide` either way; -1 if it can't be read.
int32_t sol_canvas_load_image_file(SolCanvas *canvas, const uint16_t *path, int32_t maxSide);
/// A rounded rectangle filled with an image laid out at (ix, iy, iw, ih): cropped to the rectangle and its corners.
void sol_canvas_fill_rounded_image(SolCanvas *canvas, int32_t image, float x, float y, float width, float height, float radius,
                                   float ix, float iy, float iw, float ih);
/// The wallpaper on the monitor at a point on the screen: its file (empty for none), the area it covers (left, top,
/// width, height: the monitor, or every monitor when it spans them), how it's placed, and the color around it.
int32_t sol_wallpaper_at(int32_t x, int32_t y, uint16_t *path, int32_t capacity, int32_t *area, int32_t *position, uint32_t *background);
/// A rounded rectangle filled with a linear gradient from (x0, y0) to (x1, y1) through `count` stops, each a color, an
/// alpha and a position from 0 to 1.
void sol_canvas_fill_linear(SolCanvas *canvas, float x, float y, float width, float height, float radius, float x0, float y0,
                            float x1, float y1, const uint32_t *colors, const float *alphas, const float *positions, int32_t count);
void sol_canvas_fill_rounded(SolCanvas *canvas, float x, float y, float width, float height, float radius, uint32_t color, float alpha);
void sol_canvas_stroke_rounded(SolCanvas *canvas, float x, float y, float width, float height, float radius, uint32_t color, float alpha, float thickness);
void sol_canvas_fill_ellipse(SolCanvas *canvas, float cx, float cy, float rx, float ry, uint32_t color, float alpha);
void sol_canvas_line(SolCanvas *canvas, float x1, float y1, float x2, float y2, uint32_t color, float alpha, float thickness);
/// An image from premultiplied RGBA pixels, the top row first; with `tint` other than 0xFFFFFFFF, every pixel takes that
/// color, keeping its coverage. Returns its number, as `sol_canvas_load_image` does.
int32_t sol_canvas_load_rgba(SolCanvas *canvas, const uint8_t *rgba, int32_t width, int32_t height, uint32_t tint);
/// A PNG's pixels, premultiplied RGBA, the top row first, in memory to free with `sol_canvas_free`. 0 when it worked.
int32_t sol_canvas_decode_png(SolCanvas *canvas, const uint8_t *png, int32_t length, uint8_t **rgba, int32_t *width, int32_t *height);
void sol_canvas_free(void *memory);
/// A rounded rectangle's outline in dashes `dash` long with `gap` between.
void sol_canvas_stroke_rounded_dashed(SolCanvas *canvas, float x, float y, float width, float height, float radius, uint32_t color, float alpha,
                                     float thickness, float dash, float gap);
/// Strokes SVG path data at `scale` from (x, y), `width` wide in the path's units, with round ends and joins.
void sol_canvas_stroke_svg_path(SolCanvas *canvas, const char *d, float x, float y, float scale, uint32_t color, float alpha, float width);
/// A polygon through `count` points given as x, y, x, y, …; and a line through them, closed or not, with round ends.
void sol_canvas_fill_polygon(SolCanvas *canvas, const float *xy, int32_t count, uint32_t color, float alpha);
void sol_canvas_stroke_polyline(SolCanvas *canvas, const float *xy, int32_t count, int32_t closed, uint32_t color, float alpha, float width);
/// An ellipse shading from `inner` at its center to `outer` at its edge (a glow, a stain).
void sol_canvas_fill_radial(SolCanvas *canvas, float cx, float cy, float rx, float ry, uint32_t inner, float innerAlpha, uint32_t outer, float outerAlpha);
/// A rectangle shading from `inner` at (cx, cy) to `outer` past rx, ry from it.
void sol_canvas_fill_rect_radial(SolCanvas *canvas, float x, float y, float width, float height, float cx, float cy, float rx, float ry,
                                 uint32_t inner, uint32_t outer);
/// An off-screen layer `width` by `height`, to draw into once (between `layer_begin` and `layer_end`, which send all
/// drawing there) and then draw as an image. Its number, or -1. A lost device loses it: `layer_alive` says so.
int32_t sol_canvas_layer_make(SolCanvas *canvas, float width, float height);
int32_t sol_canvas_layer_alive(SolCanvas *canvas, int32_t layer);
/// Lets a layer go, when it's no longer needed.
void sol_canvas_layer_free(SolCanvas *canvas, int32_t layer);
int32_t sol_canvas_layer_begin(SolCanvas *canvas, int32_t layer, int32_t clear);
void sol_canvas_layer_end(SolCanvas *canvas);
void sol_canvas_layer_draw(SolCanvas *canvas, int32_t layer, float x, float y, float width, float height, float alpha);
/// A font from its file's bytes (kept for as long as the canvas), for `sol_canvas_text_in`. 1 when it worked.
int32_t sol_canvas_add_font(SolCanvas *canvas, const uint8_t *data, int32_t length);
/// Wrapped text in a font family (one added with `add_font`, else the system's), `lineSpacing` added between lines; only
/// the first `shown` characters show, the rest laid out but unseen. Returns its height, and its widest line's width.
float sol_canvas_text_in(SolCanvas *canvas, const uint16_t *family, float x, float y, float width, const uint16_t *text, int32_t length,
                         float pixels, float lineSpacing, uint32_t color, float alpha, int32_t shown, int32_t measureOnly, float *usedWidth);
/// An SVG file's bytes kept for drawing (an icon pack's file icon); its number, or -1.
int32_t sol_canvas_load_svg(SolCanvas *canvas, const uint8_t *data, int32_t length);
/// Draws a kept SVG into a `size` square at (x, y). 0 when it can't (an SVG Direct2D can't read, or before Windows 10 1703).
int32_t sol_canvas_draw_svg(SolCanvas *canvas, int32_t svg, float x, float y, float size);
/// An icon pack's font (TrueType, OpenType, WOFF or WOFF2) from its bytes; its number, or -1.
int32_t sol_canvas_load_icon_font(SolCanvas *canvas, const uint8_t *data, int32_t length);
/// A character of an icon font, centered in a `size` square at (x, y), sized as VS Code does (`scale` of its 13px font
/// in a 16px square) and shrunk to fit. 0 when the font hasn't it.
int32_t sol_canvas_draw_icon_glyph(SolCanvas *canvas, int32_t font, uint32_t codepoint, float x, float y, float size, float scale,
                                   uint32_t color, float alpha);
/// Downloads a URL to a file, waiting for it: an HRESULT, 0 when it worked. Run it off the window's thread.
int32_t sol_download_file(const uint16_t *url, const uint16_t *path);
/// Fills SVG path data (a <path>'s `d`) drawn at `scale` from (x, y): moves, lines, curves and arcs.
void sol_canvas_fill_svg_path(SolCanvas *canvas, const char *d, float x, float y, float scale, uint32_t color, float alpha);
void sol_canvas_push_clip(SolCanvas *canvas, float x, float y, float width, float height);
void sol_canvas_pop_clip(SolCanvas *canvas);
/// Draws what comes until `sol_canvas_pop_opacity` see-through, as one: a dragged tab, say.
void sol_canvas_push_opacity(SolCanvas *canvas, float opacity);
void sol_canvas_pop_opacity(SolCanvas *canvas);

/// Text in the system interface font, vertically centered in the rectangle, cut with "…" if it doesn't fit. `semibold` is a
/// set of bits: 1 semibold, 2 italic (for the label functions; paragraphs take 1 only).
void sol_canvas_draw_label(SolCanvas *canvas, float x, float y, float width, float height, const uint16_t *text, int32_t length,
                           float pixels, int32_t semibold, uint32_t color, float alpha);
float sol_canvas_measure_label(SolCanvas *canvas, const uint16_t *text, int32_t length, float pixels, int32_t semibold);

/// Text in the interface font, wrapped to `width`. Returns the height it takes; draws nothing when measuring.
float sol_canvas_paragraph(SolCanvas *canvas, float x, float y, float width, const uint16_t *text, int32_t length, float pixels,
                           int32_t semibold, uint32_t color, float alpha, int32_t measureOnly);

/// A glyph of the system icon font (Segoe Fluent Icons, or Segoe MDL2 Assets before Windows 11), centered in the rectangle.
void sol_canvas_draw_icon(SolCanvas *canvas, float x, float y, float width, float height, uint16_t glyph, float pixels, uint32_t color, float alpha);

/// Decodes an image for `sol_canvas_draw_image`: a PNG, or anything else Windows' codecs read (JPEG, GIF, BMP, TIFF, ICO,
/// and WebP where its codec is installed). Returns its number, or a negative value if it can't be read.
int32_t sol_canvas_load_image(SolCanvas *canvas, const uint8_t *png, int32_t length);
void sol_canvas_draw_image(SolCanvas *canvas, int32_t image, float x, float y, float width, float height, float alpha);
/// An image's size in pixels; 0 by 0 if there's no such image.
void sol_canvas_image_size(SolCanvas *canvas, int32_t image, int32_t *width, int32_t *height);
/// Lets go of an image's memory. Its number isn't used again.
void sol_canvas_free_image(SolCanvas *canvas, int32_t image);

/// Bitmap canvases only. `path` is NUL-terminated UTF-16.
int32_t sol_canvas_save_png(SolCanvas *canvas, const uint16_t *path);

/// Encrypts (or, with `reveal`, decrypts) memory in place so only this process can read it: Windows' CryptProtectMemory.
/// `length` must be a multiple of 16. Returns false if it failed.
int32_t sol_protect_memory(void *bytes, uint32_t length, int32_t reveal);

#ifdef __cplusplus
}
#endif
