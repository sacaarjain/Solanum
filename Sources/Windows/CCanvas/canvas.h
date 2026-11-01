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

/// Bitmap canvases only. `path` is NUL-terminated UTF-16.
int32_t sol_canvas_save_png(SolCanvas *canvas, const uint16_t *path);

#ifdef __cplusplus
}
#endif
