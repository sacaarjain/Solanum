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

/// On failure these return NULL and set `hr`.
SolCanvas *sol_canvas_create_window(void *hwnd, float fontPixels, int32_t *hr);
SolCanvas *sol_canvas_create_bitmap(int32_t width, int32_t height, float fontPixels, int32_t *hr);
void sol_canvas_destroy(SolCanvas *canvas);

SolMetrics sol_canvas_metrics(SolCanvas *canvas);
int32_t sol_canvas_set_font_pixels(SolCanvas *canvas, float fontPixels);
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
void sol_canvas_fill_rounded(SolCanvas *canvas, float x, float y, float width, float height, float radius, uint32_t color, float alpha);
void sol_canvas_stroke_rounded(SolCanvas *canvas, float x, float y, float width, float height, float radius, uint32_t color, float alpha, float thickness);
void sol_canvas_fill_ellipse(SolCanvas *canvas, float cx, float cy, float rx, float ry, uint32_t color, float alpha);
void sol_canvas_line(SolCanvas *canvas, float x1, float y1, float x2, float y2, uint32_t color, float alpha, float thickness);
void sol_canvas_push_clip(SolCanvas *canvas, float x, float y, float width, float height);
void sol_canvas_pop_clip(SolCanvas *canvas);

/// Text in the system interface font, vertically centered in the rectangle, cut with "…" if it doesn't fit.
void sol_canvas_draw_label(SolCanvas *canvas, float x, float y, float width, float height, const uint16_t *text, int32_t length,
                           float pixels, int32_t semibold, uint32_t color, float alpha);
float sol_canvas_measure_label(SolCanvas *canvas, const uint16_t *text, int32_t length, float pixels, int32_t semibold);

/// A glyph of the system icon font (Segoe Fluent Icons, or Segoe MDL2 Assets before Windows 11), centered in the rectangle.
void sol_canvas_draw_icon(SolCanvas *canvas, float x, float y, float width, float height, uint16_t glyph, float pixels, uint32_t color, float alpha);

/// Decodes a PNG for `sol_canvas_draw_image`. Returns its number, or a negative value if it can't be read.
int32_t sol_canvas_load_image(SolCanvas *canvas, const uint8_t *png, int32_t length);
void sol_canvas_draw_image(SolCanvas *canvas, int32_t image, float x, float y, float width, float height, float alpha);

/// Bitmap canvases only. `path` is NUL-terminated UTF-16.
int32_t sol_canvas_save_png(SolCanvas *canvas, const uint16_t *path);

#ifdef __cplusplus
}
#endif
