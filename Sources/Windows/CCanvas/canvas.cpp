#include "canvas.h"

#include <windows.h>
#include <d2d1.h>
#include <d2d1_1.h>
#include <d2d1_3.h>
#include <d2d1effects.h>
#include <shlwapi.h>
#include <urlmon.h>
#include <dwmapi.h>
#include <dpapi.h>
#include <dwrite.h>
#include <dwrite_3.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <map>
#include <string>
#include <utility>
#include <vector>

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dxguid.lib")
#pragma comment(lib, "dwrite.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "urlmon.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "crypt32.lib")

using Microsoft::WRL::ComPtr;

namespace {

const wchar_t *const kFontFamilies[] = {L"Cascadia Mono", L"Consolas", L"Courier New"};

D2D1_COLOR_F color(uint32_t rgb, float alpha = 1) {
    return D2D1::ColorF(((rgb >> 16) & 0xFF) / 255.0f, ((rgb >> 8) & 0xFF) / 255.0f, (rgb & 0xFF) / 255.0f, alpha);
}

/// Pictographs go through system fallback, which is what draws them in color.
bool wantsColorFont(uint32_t scalar) { return scalar >= 0x1F000 && scalar < 0x20000; }

}  // namespace

struct SolCanvas {
    ComPtr<ID2D1Factory> d2d;
    ComPtr<IDWriteFactory> dwrite;
    ComPtr<IWICImagingFactory> wic;
    ComPtr<IWICBitmap> bitmap;
    HWND hwnd = nullptr;
    UINT32 width = 0, height = 0;

    ComPtr<ID2D1RenderTarget> target;
    ComPtr<ID2D1HwndRenderTarget> windowTarget;
    /// The window target as a device context, for drawing that replaces what's under it (see `backdrop`); null if the
    /// system can't.
    ComPtr<ID2D1DeviceContext> context;
    /// How opaque the window's own backgrounds are, below 1 when the desktop shows through (see `sol_canvas_set_opacity`).
    float opacity = 1;
    /// Whether the window target keeps alpha, which a see-through window needs.
    bool transparent = false;

    /// The desktop wallpaper as it lies on the window's monitor, blurred, drawn under the window's own backgrounds so
    /// it shows through them in place of the windows behind (see `sol_canvas_set_wallpaper`). Its size in pixels is
    /// the monitor's times `wallpaperScale`; `wallpaperOrigin` is the monitor's top left in the window.
    ComPtr<IWICBitmap> wallpaper;
    ComPtr<ID2D1BitmapBrush> wallpaperBrush;
    float wallpaperScale = 1;
    D2D1_POINT_2F wallpaperOrigin = {0, 0};
    /// Drawn this much bigger than the area it was made for: a theme's picture zoomed to fill the window.
    float wallpaperZoom = 1;
    /// The picture as placed, before blurring, so changing only the blur doesn't read the file again.
    std::vector<BYTE> wallpaperPlaced;
    std::wstring wallpaperPlacedKey;

    /// The wallpaper as a brush lined up with the screen, while the backgrounds are see-through; else null.
    ID2D1Brush *wallpaperPaint() {
        if (!wallpaper || opacity >= 1 || !target) return nullptr;
        if (!wallpaperBrush) {
            ComPtr<ID2D1Bitmap> device;
            if (FAILED(target->CreateBitmapFromWicBitmap(wallpaper.Get(), &device))) return nullptr;
            auto props = D2D1::BitmapBrushProperties(D2D1_EXTEND_MODE_CLAMP, D2D1_EXTEND_MODE_CLAMP, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
            if (FAILED(target->CreateBitmapBrush(device.Get(), props, &wallpaperBrush))) return nullptr;
        }
        wallpaperBrush->SetTransform(D2D1::Matrix3x2F::Scale(wallpaperZoom / wallpaperScale, wallpaperZoom / wallpaperScale) *
                                     D2D1::Matrix3x2F::Translation(wallpaperOrigin.x, wallpaperOrigin.y));
        return wallpaperBrush.Get();
    }
    ComPtr<ID2D1SolidColorBrush> brush;

    ComPtr<IDWriteFontFace> faces[4];
    ComPtr<IDWriteTextFormat> formats[4];
    SolMetrics metrics = {};
    float fontPixels = 0;
    std::wstring preferredFamily;
    float lineHeight = 0;
    float emScale = 0;

    std::map<std::pair<int, int>, ComPtr<IDWriteTextFormat>> labelFormats;
    std::map<int, ComPtr<IDWriteTextFormat>> iconFormats;

    /// Decoded images, and the same on the graphics device, made when first drawn and again if the device is lost.
    std::vector<ComPtr<IWICBitmapSource>> images;
    std::vector<ComPtr<ID2D1Bitmap>> deviceImages;

    std::vector<UINT16> glyphs;
    std::vector<FLOAT> advances;

    /// SVG paths made into geometry, by their path data. Geometry belongs to the factory, so it outlives a lost device.
    std::map<std::string, ComPtr<ID2D1PathGeometry>> svgPaths;
    ComPtr<ID2D1StrokeStyle> roundStroke;

    /// Off-screen layers, drawn into once and then drawn as images (see `sol_canvas_layer_make`). Lost with the device.
    std::vector<ComPtr<ID2D1BitmapRenderTarget>> layers;
    /// While a layer's being drawn into: the target to go back to.
    ComPtr<ID2D1RenderTarget> savedTarget;

    /// File icons from an icon pack (see `sol_canvas_load_svg`): each SVG's bytes, and its document for each size it's
    /// drawn at (lost with the device; a size that couldn't be made is remembered as null).
    std::vector<std::vector<uint8_t>> svgData;
    std::map<std::pair<int, int>, ComPtr<ID2D1SvgDocument>> svgDocuments;
    /// Icon packs' fonts (Seti's), each a face of its own.
    std::vector<ComPtr<IDWriteFontFace>> iconFaces;
    std::vector<std::vector<uint8_t>> iconFontData;
    ComPtr<IDWriteInMemoryFontFileLoader> iconFontLoader;

    /// Fonts that came with Solanum rather than the system (Space Mono), and text formats in them.
    ComPtr<IDWriteFontCollection> privateFonts;
    std::map<std::pair<std::wstring, int>, ComPtr<IDWriteTextFormat>> privateFormats;

    HRESULT createTarget() {
        windowTarget.Reset();
        target.Reset();
        brush.Reset();
        for (auto &image : deviceImages) image.Reset();
        for (auto &layer : layers) layer.Reset();
        wallpaperBrush.Reset();
        svgDocuments.clear();
        HRESULT hr;
        // 96 DPI makes one Direct2D unit one pixel.
        if (hwnd) {
            auto format = transparent ? D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED) : D2D1::PixelFormat();
            auto props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, format, 96, 96);
            auto window = D2D1::HwndRenderTargetProperties(hwnd, D2D1::SizeU(width, height));
            hr = d2d->CreateHwndRenderTarget(props, window, &windowTarget);
            if (FAILED(hr)) return hr;
            target = windowTarget;
            context.Reset();
            windowTarget.As(&context);
            // ClearType needs something solid under the text to blend with.
            if (transparent) target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        } else {
            auto props = D2D1::RenderTargetProperties(
                D2D1_RENDER_TARGET_TYPE_SOFTWARE,
                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
            hr = d2d->CreateWicBitmapRenderTarget(bitmap.Get(), props, &target);
            if (FAILED(hr)) return hr;
            target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        }
        // Cells meet exactly, without seams between backgrounds.
        target->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
        return target->CreateSolidColorBrush(color(0xFFFFFF), &brush);
    }

    HRESULT loadFonts(float pixels) {
        ComPtr<IDWriteFontCollection> fonts;
        HRESULT hr = dwrite->GetSystemFontCollection(&fonts);
        if (FAILED(hr)) return hr;
        ComPtr<IDWriteFontFamily> family;
        const wchar_t *familyName = nullptr;
        std::vector<const wchar_t *> names;
        if (!preferredFamily.empty()) names.push_back(preferredFamily.c_str());
        for (const wchar_t *name : kFontFamilies) names.push_back(name);
        for (const wchar_t *name : names) {
            UINT32 index = 0;
            BOOL exists = FALSE;
            if (SUCCEEDED(fonts->FindFamilyName(name, &index, &exists)) && exists &&
                SUCCEEDED(fonts->GetFontFamily(index, &family))) {
                familyName = name;
                break;
            }
        }
        if (!familyName) return E_FAIL;
        for (int style = 0; style < 4; style++) {
            auto weight = (style & SOL_STYLE_BOLD) ? DWRITE_FONT_WEIGHT_BOLD : DWRITE_FONT_WEIGHT_NORMAL;
            auto slant = (style & SOL_STYLE_ITALIC) ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL;
            ComPtr<IDWriteFont> font;
            hr = family->GetFirstMatchingFont(weight, DWRITE_FONT_STRETCH_NORMAL, slant, &font);
            if (FAILED(hr)) return hr;
            faces[style].Reset();
            hr = font->CreateFontFace(&faces[style]);
            if (FAILED(hr)) return hr;
            formats[style].Reset();
            hr = dwrite->CreateTextFormat(familyName, nullptr, weight, slant, DWRITE_FONT_STRETCH_NORMAL, pixels, L"",
                                          &formats[style]);
            if (FAILED(hr)) return hr;
            formats[style]->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        }

        DWRITE_FONT_METRICS m;
        faces[0]->GetMetrics(&m);
        emScale = pixels / m.designUnitsPerEm;
        UINT32 sample = 'M';
        UINT16 glyph = 0;
        DWRITE_GLYPH_METRICS sampleMetrics = {};
        hr = faces[0]->GetGlyphIndices(&sample, 1, &glyph);
        if (FAILED(hr)) return hr;
        hr = faces[0]->GetDesignGlyphMetrics(&glyph, 1, &sampleMetrics);
        if (FAILED(hr)) return hr;

        fontPixels = pixels;
        metrics.cellWidth = std::round(sampleMetrics.advanceWidth * emScale);
        float natural = (m.ascent + m.descent + m.lineGap) * emScale;
        metrics.cellHeight = std::round(lineHeight > 0 ? std::fmax(pixels * lineHeight, (m.ascent + m.descent) * emScale) : natural);
        // The extra height is shared above and below the text.
        metrics.baseline = std::round(m.ascent * emScale + (metrics.cellHeight - (m.ascent + m.descent) * emScale) / 2.0f);
        metrics.lineThickness = std::fmax(1.0f, std::round(m.underlineThickness * emScale));
        metrics.underlineY = metrics.baseline - std::round(m.underlinePosition * emScale);
        metrics.strikeY = metrics.baseline - std::round(m.strikethroughPosition * emScale);
        for (auto &format : formats) {
            format->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, metrics.cellHeight, metrics.baseline);
        }
        return S_OK;
    }

    HRESULT createFactories(float pixels) {
        HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.GetAddressOf());
        if (FAILED(hr)) return hr;
        hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                 reinterpret_cast<IUnknown **>(dwrite.GetAddressOf()));
        if (FAILED(hr)) return hr;
        return loadFonts(pixels);
    }

    IDWriteTextFormat *labelFormat(float pixels, int semibold) {
        auto key = std::make_pair(static_cast<int>(pixels * 10), semibold);
        auto found = labelFormats.find(key);
        if (found != labelFormats.end()) return found->second.Get();
        ComPtr<IDWriteTextFormat> format;
        // `semibold` is a set of bits: 1 semibold, 2 italic.
        auto weight = (semibold & 1) ? DWRITE_FONT_WEIGHT_SEMI_BOLD : DWRITE_FONT_WEIGHT_NORMAL;
        auto style = (semibold & 2) ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL;
        if (FAILED(dwrite->CreateTextFormat(L"Segoe UI", nullptr, weight, style, DWRITE_FONT_STRETCH_NORMAL,
                                            pixels, L"", &format))) return nullptr;
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        ComPtr<IDWriteInlineObject> ellipsis;
        dwrite->CreateEllipsisTrimmingSign(format.Get(), &ellipsis);
        DWRITE_TRIMMING trimming = {DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        format->SetTrimming(&trimming, ellipsis.Get());
        labelFormats[key] = format;
        return format.Get();
    }

    std::map<std::pair<int, int>, ComPtr<IDWriteTextFormat>> paragraphFormats;

    IDWriteTextFormat *paragraphFormat(float pixels, int semibold) {
        auto key = std::make_pair(static_cast<int>(pixels * 10), semibold);
        auto found = paragraphFormats.find(key);
        if (found != paragraphFormats.end()) return found->second.Get();
        ComPtr<IDWriteTextFormat> format;
        auto weight = semibold ? DWRITE_FONT_WEIGHT_SEMI_BOLD : DWRITE_FONT_WEIGHT_NORMAL;
        if (FAILED(dwrite->CreateTextFormat(L"Segoe UI", nullptr, weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                            pixels, L"", &format))) return nullptr;
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
        paragraphFormats[key] = format;
        return format.Get();
    }

    IDWriteTextFormat *iconFormat(float pixels) {
        int key = static_cast<int>(pixels * 10);
        auto found = iconFormats.find(key);
        if (found != iconFormats.end()) return found->second.Get();
        ComPtr<IDWriteFontCollection> fonts;
        if (FAILED(dwrite->GetSystemFontCollection(&fonts))) return nullptr;
        UINT32 index = 0;
        BOOL exists = FALSE;
        fonts->FindFamilyName(L"Segoe Fluent Icons", &index, &exists);
        ComPtr<IDWriteTextFormat> format;
        if (FAILED(dwrite->CreateTextFormat(exists ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
                                            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, pixels, L"", &format))) return nullptr;
        format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        iconFormats[key] = format;
        return format.Get();
    }

    /// Runs `draw` with shapes antialiased, then goes back to the terminal's exact cell edges.
    template <typename Draw> void smooth(Draw draw) {
        target->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        draw();
        target->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
    }

    void drawRun(float x, float y, int style) {
        if (glyphs.empty()) return;
        DWRITE_GLYPH_RUN run = {};
        run.fontFace = faces[style].Get();
        run.fontEmSize = fontPixels;
        run.glyphCount = static_cast<UINT32>(glyphs.size());
        run.glyphIndices = glyphs.data();
        run.glyphAdvances = advances.data();
        target->DrawGlyphRun(D2D1::Point2F(x, y + metrics.baseline), &run, brush.Get());
        glyphs.clear();
        advances.clear();
    }

    void drawFallback(float x, float y, int cells, const WCHAR *text, UINT32 length, int style) {
        float right = x + cells * metrics.cellWidth;
        auto rect = D2D1::RectF(x, y, right, y + metrics.cellHeight);
        target->DrawText(text, length, formats[style].Get(), rect, brush.Get(), D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    }
};

extern "C" {

void sol_enable_dpi_awareness(void) { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2); }

void sol_use_dark_titlebar(void *hwnd) {
    BOOL dark = TRUE;
    DwmSetWindowAttribute(static_cast<HWND>(hwnd), DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
}

SolCanvas *sol_canvas_create_window(void *hwnd, float fontPixels, int32_t *result) {
    auto *canvas = new SolCanvas();
    canvas->hwnd = static_cast<HWND>(hwnd);
    RECT client = {};
    GetClientRect(canvas->hwnd, &client);
    canvas->width = static_cast<UINT32>(client.right - client.left);
    canvas->height = static_cast<UINT32>(client.bottom - client.top);
    // S_FALSE just means COM was already started on this thread.
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (hr == RPC_E_CHANGED_MODE) hr = S_OK;
    if (SUCCEEDED(hr)) hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&canvas->wic));
    if (SUCCEEDED(hr)) hr = canvas->createFactories(fontPixels);
    if (SUCCEEDED(hr)) hr = canvas->createTarget();
    if (result) *result = hr;
    if (FAILED(hr)) {
        delete canvas;
        return nullptr;
    }
    return canvas;
}

SolCanvas *sol_canvas_create_bitmap(int32_t width, int32_t height, float fontPixels, int32_t *result) {
    auto *canvas = new SolCanvas();
    canvas->width = static_cast<UINT32>(width);
    canvas->height = static_cast<UINT32>(height);
    // S_FALSE just means COM was already started on this thread.
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (hr == RPC_E_CHANGED_MODE) hr = S_OK;
    if (SUCCEEDED(hr)) {
        hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&canvas->wic));
    }
    if (SUCCEEDED(hr)) {
        hr = canvas->wic->CreateBitmap(canvas->width, canvas->height, GUID_WICPixelFormat32bppPBGRA,
                                       WICBitmapCacheOnLoad, &canvas->bitmap);
    }
    if (SUCCEEDED(hr)) hr = canvas->createFactories(fontPixels);
    if (SUCCEEDED(hr)) hr = canvas->createTarget();
    if (result) *result = hr;
    if (FAILED(hr)) {
        delete canvas;
        return nullptr;
    }
    return canvas;
}

void sol_canvas_destroy(SolCanvas *canvas) { delete canvas; }

SolMetrics sol_canvas_metrics(SolCanvas *canvas) { return canvas->metrics; }

int32_t sol_canvas_set_font_pixels(SolCanvas *canvas, float fontPixels) { return canvas->loadFonts(fontPixels); }

int32_t sol_canvas_set_font(SolCanvas *canvas, const uint16_t *family, float fontPixels, float lineHeight) {
    canvas->preferredFamily = family ? std::wstring(reinterpret_cast<const wchar_t *>(family)) : std::wstring();
    canvas->lineHeight = lineHeight;
    return canvas->loadFonts(fontPixels);
}

void sol_canvas_resize(SolCanvas *canvas, int32_t width, int32_t height) {
    canvas->width = static_cast<UINT32>(width);
    canvas->height = static_cast<UINT32>(height);
    if (canvas->windowTarget) canvas->windowTarget->Resize(D2D1::SizeU(canvas->width, canvas->height));
}

int32_t sol_canvas_begin(SolCanvas *canvas, uint32_t background) {
    // A lost graphics device (a driver update, a remote session) drops the target; `end` reports that.
    if (!canvas->target) {
        HRESULT hr = canvas->createTarget();
        if (FAILED(hr)) return hr;
    }
    canvas->target->BeginDraw();
    // Over the wallpaper, the window is solid; it only looks see-through.
    canvas->target->Clear(color(background, canvas->wallpaper ? 1 : canvas->opacity));
    if (auto *wall = canvas->wallpaperPaint()) {
        auto size = canvas->target->GetSize();
        canvas->target->FillRectangle(D2D1::RectF(0, 0, size.width, size.height), wall);
        canvas->brush->SetColor(color(background, canvas->opacity));
        canvas->target->FillRectangle(D2D1::RectF(0, 0, size.width, size.height), canvas->brush.Get());
    }
    return S_OK;
}

int32_t sol_canvas_end(SolCanvas *canvas) {
    HRESULT hr = canvas->target->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) {
        for (auto &image : canvas->deviceImages) image.Reset();
        canvas->target.Reset();
        canvas->windowTarget.Reset();
        canvas->context.Reset();
        canvas->brush.Reset();
    }
    return hr;
}

void sol_canvas_fill_rect(SolCanvas *canvas, float x, float y, float width, float height, uint32_t rgb, float alpha) {
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->target->FillRectangle(D2D1::RectF(x, y, x + width, y + height), canvas->brush.Get());
}

void sol_canvas_stroke_rect(SolCanvas *canvas, float x, float y, float width, float height, uint32_t rgb,
                            float thickness) {
    canvas->brush->SetColor(color(rgb));
    float inset = thickness / 2;
    auto rect = D2D1::RectF(x + inset, y + inset, x + width - inset, y + height - inset);
    canvas->target->DrawRectangle(rect, canvas->brush.Get(), thickness);
}

void sol_canvas_draw_cells(SolCanvas *canvas, float x, float y, const uint32_t *scalars, const uint8_t *widths,
                           int32_t count, uint32_t rgb, int32_t style) {
    if (count <= 0) return;
    style &= 3;
    canvas->brush->SetColor(color(rgb));
    std::vector<UINT16> indices(static_cast<size_t>(count));
    if (FAILED(canvas->faces[style]->GetGlyphIndices(scalars, static_cast<UINT32>(count), indices.data()))) return;

    float cellWidth = canvas->metrics.cellWidth;
    float runX = x, cursor = x;
    for (int32_t i = 0; i < count; i++) {
        float advance = widths[i] * cellWidth;
        if (indices[i] == 0 || wantsColorFont(scalars[i])) {
            canvas->drawRun(runX, y, style);
            WCHAR text[2];
            UINT32 length = 1;
            uint32_t scalar = scalars[i];
            if (scalar >= 0x10000) {
                scalar -= 0x10000;
                text[0] = static_cast<WCHAR>(0xD800 + (scalar >> 10));
                text[1] = static_cast<WCHAR>(0xDC00 + (scalar & 0x3FF));
                length = 2;
            } else {
                text[0] = static_cast<WCHAR>(scalar);
            }
            canvas->drawFallback(cursor, y, widths[i], text, length, style);
            cursor += advance;
            runX = cursor;
        } else {
            canvas->glyphs.push_back(indices[i]);
            canvas->advances.push_back(advance);
            cursor += advance;
        }
    }
    canvas->drawRun(runX, y, style);
}

void sol_canvas_draw_text(SolCanvas *canvas, float x, float y, int32_t cells, const uint16_t *text, int32_t length,
                          uint32_t rgb, int32_t style) {
    if (length <= 0) return;
    canvas->brush->SetColor(color(rgb));
    canvas->drawFallback(x, y, cells, reinterpret_cast<const WCHAR *>(text), static_cast<UINT32>(length), style & 3);
}

/// Runs `draw` so that what it fills replaces what's under it, rather than being laid over it: the window's own
/// backgrounds, which must stay as see-through as asked even where one is drawn over another.
/// `shape` fills the shape with the brush it's given: here the wallpaper, then `paint` over it, when the wallpaper shows
/// through; else just `paint`, replacing what's under it.
extern "C++" template <typename F> void backdrop(SolCanvas *canvas, ID2D1Brush *paint, F shape) {
    if (auto *wall = canvas->wallpaperPaint()) {
        shape(wall);
        shape(paint);
        return;
    }
    bool copy = canvas->opacity < 1 && canvas->context && canvas->target.Get() == canvas->windowTarget.Get();
    if (copy) canvas->context->SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND_COPY);
    shape(paint);
    if (copy) canvas->context->SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND_SOURCE_OVER);
}

/// The window target keeps alpha only while the desktop itself shows through: see-through, without the wallpaper drawn in.
extern "C++" void updateTransparency(SolCanvas *canvas) {
    bool transparent = canvas->opacity < 1 && !canvas->wallpaper;
    if (!canvas->hwnd || transparent == canvas->transparent) return;
    canvas->transparent = transparent;
    // Made again, with or without alpha, at the next frame.
    for (auto &image : canvas->deviceImages) image.Reset();
    for (auto &layer : canvas->layers) layer.Reset();
    canvas->target.Reset();
    canvas->windowTarget.Reset();
    canvas->context.Reset();
    canvas->brush.Reset();
}

void sol_canvas_set_opacity(SolCanvas *canvas, float opacity) {
    canvas->opacity = opacity < 0 ? 0 : (opacity > 1 ? 1 : opacity);
    updateTransparency(canvas);
}

void sol_canvas_backdrop_rect(SolCanvas *canvas, float x, float y, float width, float height, uint32_t rgb) {
    canvas->brush->SetColor(color(rgb, canvas->opacity));
    backdrop(canvas, canvas->brush.Get(), [&](ID2D1Brush *b) { canvas->target->FillRectangle(D2D1::RectF(x, y, x + width, y + height), b); });
}

void sol_canvas_backdrop_rounded(SolCanvas *canvas, float x, float y, float width, float height, float radius, uint32_t rgb) {
    canvas->brush->SetColor(color(rgb, canvas->opacity));
    backdrop(canvas, canvas->brush.Get(), [&](ID2D1Brush *b) {
        canvas->smooth([&] {
            canvas->target->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(x, y, x + width, y + height), radius, radius), b);
        });
    });
}

void sol_canvas_backdrop_frame(SolCanvas *canvas, float x, float y, float width, float height, const float *cards, int32_t count, float radius, uint32_t rgb) {
    ComPtr<ID2D1RectangleGeometry> outer;
    if (FAILED(canvas->d2d->CreateRectangleGeometry(D2D1::RectF(x, y, x + width, y + height), &outer))) return;
    ComPtr<ID2D1Geometry> shape = outer;
    for (int32_t i = 0; i < count; i++) {
        const float *c = cards + i * 4;
        if (c[2] <= 0 || c[3] <= 0) continue;
        ComPtr<ID2D1RoundedRectangleGeometry> card;
        ComPtr<ID2D1PathGeometry> path;
        ComPtr<ID2D1GeometrySink> sink;
        if (FAILED(canvas->d2d->CreateRoundedRectangleGeometry(D2D1::RoundedRect(D2D1::RectF(c[0], c[1], c[0] + c[2], c[1] + c[3]), radius, radius), &card)) ||
            FAILED(canvas->d2d->CreatePathGeometry(&path)) || FAILED(path->Open(&sink))) return;
        if (FAILED(shape->CombineWithGeometry(card.Get(), D2D1_COMBINE_MODE_EXCLUDE, nullptr, sink.Get())) || FAILED(sink->Close())) return;
        shape = path;
    }
    canvas->brush->SetColor(color(rgb, canvas->opacity));
    backdrop(canvas, canvas->brush.Get(), [&](ID2D1Brush *b) {
        canvas->smooth([&] { canvas->target->FillGeometry(shape.Get(), b); });
    });
}

/// Frosted glass, as a Mac popover's: what's already drawn under the rounded rectangle, blurred, then a wash of `tint`
/// over it. Where the system can't blur (or `blur` is 0) the wash is drawn solid instead.
int32_t sol_canvas_frost_rounded(SolCanvas *canvas, float x, float y, float width, float height, float radius, float blur, uint32_t tint,
                                 float tintAlpha) {
    const auto shapeRect = D2D1::RoundedRect(D2D1::RectF(x, y, x + width, y + height), radius, radius);
    int32_t step = 0;
    ComPtr<ID2D1DeviceContext> dc;
    if (blur > 0 && SUCCEEDED(canvas->target.As(&dc))) {
        step = -1;
        // What's under it, with a margin so the blur near its edges has something to take from.
        const D2D1_SIZE_U size = canvas->target->GetPixelSize();
        const float m = blur * 2;
        const UINT32 l = static_cast<UINT32>((std::max)(0.0f, std::floor(x - m)));
        const UINT32 t = static_cast<UINT32>((std::max)(0.0f, std::floor(y - m)));
        const UINT32 r = (std::min)(size.width, static_cast<UINT32>((std::max)(0.0f, std::ceil(x + width + m))));
        const UINT32 b = (std::min)(size.height, static_cast<UINT32>((std::max)(0.0f, std::ceil(y + height + m))));
        ComPtr<ID2D1Bitmap1> under;
        D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_NONE, canvas->target->GetPixelFormat());
        dc->GetDpi(&props.dpiX, &props.dpiY);
        const D2D1_POINT_2U origin = {0, 0};
        const D2D1_RECT_U source = {l, t, r, b};
        ComPtr<ID2D1Effect> fx;
        ComPtr<ID2D1RoundedRectangleGeometry> shape;
        if (r > l && b > t && SUCCEEDED(dc->CreateBitmap(D2D1::SizeU(r - l, b - t), nullptr, 0, props, &under)) && (step = -2) &&
            SUCCEEDED(under->CopyFromRenderTarget(&origin, canvas->target.Get(), &source)) && (step = -3) &&
            SUCCEEDED(dc->CreateEffect(CLSID_D2D1GaussianBlur, &fx)) && (step = -4) &&
            SUCCEEDED(canvas->d2d->CreateRoundedRectangleGeometry(shapeRect, &shape))) {
            fx->SetInput(0, under.Get());
            fx->SetValue(D2D1_GAUSSIANBLUR_PROP_STANDARD_DEVIATION, blur / 2);
            fx->SetValue(D2D1_GAUSSIANBLUR_PROP_BORDER_MODE, D2D1_BORDER_MODE_HARD);
            dc->PushLayer(D2D1::LayerParameters1(D2D1::InfiniteRect(), shape.Get(), D2D1_ANTIALIAS_MODE_PER_PRIMITIVE), nullptr);
            dc->DrawImage(fx.Get(), D2D1::Point2F(static_cast<float>(l), static_cast<float>(t)));
            dc->PopLayer();
            step = 1;
        }
    }
    canvas->brush->SetColor(color(tint, step == 1 ? tintAlpha : 1));
    canvas->smooth([&] { canvas->target->FillRoundedRectangle(shapeRect, canvas->brush.Get()); });
    return step;
}

/// Three box blurs one way and three the other come close to a Gaussian.
extern "C++" void boxBlur(std::vector<BYTE> &px, int w, int h, int radius) {
    if (radius < 1 || w < 2 || h < 2) return;
    std::vector<BYTE> tmp(px.size());
    auto pass = [&](const BYTE *src, BYTE *dst, int count, int length, int step, int lineStep) {
        const int window = radius * 2 + 1;
        for (int line = 0; line < count; line++) {
            const BYTE *s = src + static_cast<size_t>(line) * lineStep;
            BYTE *d = dst + static_cast<size_t>(line) * lineStep;
            for (int c = 0; c < 4; c++) {
                int sum = 0;
                for (int k = -radius; k <= radius; k++) sum += s[static_cast<size_t>((std::min)((std::max)(k, 0), length - 1)) * step + c];
                for (int i = 0; i < length; i++) {
                    d[static_cast<size_t>(i) * step + c] = static_cast<BYTE>(sum / window);
                    int out = (std::max)(i - radius, 0), in = (std::min)(i + radius + 1, length - 1);
                    sum += s[static_cast<size_t>(in) * step + c] - s[static_cast<size_t>(out) * step + c];
                }
            }
        }
    };
    for (int k = 0; k < 3; k++) {
        pass(px.data(), tmp.data(), h, w, 4, w * 4);
        pass(tmp.data(), px.data(), w, h, w * 4, 4);
    }
}

int32_t sol_canvas_set_wallpaper(SolCanvas *canvas, const uint16_t *path, int32_t width, int32_t height, int32_t position,
                                 uint32_t background, float blur) {
    canvas->wallpaper.Reset();
    canvas->wallpaperBrush.Reset();
    int32_t result = 0;
    if (width > 0 && height > 0 && (path || background != 0xFFFFFFFF)) {
        // Blurred, it's made smaller: the blur hides it, and it's quick to make and to draw.
        const float scale = blur >= 16 ? 0.25f : (blur > 0 ? 0.5f : 1.0f);
        const int ow = (std::max)(1, static_cast<int>(width * scale + 0.5f)), oh = (std::max)(1, static_cast<int>(height * scale + 0.5f));
        std::vector<BYTE> px(static_cast<size_t>(ow) * oh * 4);
        std::wstring key = (path ? std::wstring(reinterpret_cast<const wchar_t *>(path)) : L"") + L"|" + std::to_wstring(ow) + L"x" +
                           std::to_wstring(oh) + L"|" + std::to_wstring(position) + L"|" + std::to_wstring(background);
        const bool cached = key == canvas->wallpaperPlacedKey && canvas->wallpaperPlaced.size() == px.size();
        if (cached) px = canvas->wallpaperPlaced;
        else {
        for (size_t i = 0; i < px.size(); i += 4) {
            px[i] = background & 0xFF;
            px[i + 1] = (background >> 8) & 0xFF;
            px[i + 2] = (background >> 16) & 0xFF;
            px[i + 3] = 255;
        }
        ComPtr<IWICBitmapDecoder> decoder;
        ComPtr<IWICBitmapFrameDecode> frame;
        UINT iw = 0, ih = 0;
        if (path && SUCCEEDED(canvas->wic->CreateDecoderFromFilename(reinterpret_cast<const wchar_t *>(path), nullptr, GENERIC_READ,
                                                                     WICDecodeMetadataCacheOnDemand, &decoder)) &&
            SUCCEEDED(decoder->GetFrame(0, &frame)) && SUCCEEDED(frame->GetSize(&iw, &ih)) && iw > 0 && ih > 0) {
            // Where the picture goes on the monitor, as Windows places it (DESKTOP_WALLPAPER_POSITION).
            float sx = 1, sy = 1;
            switch (position) {
            case 0: case 1: break;                                                              // center, tile: as it is
            case 2: sx = static_cast<float>(width) / iw; sy = static_cast<float>(height) / ih; break;  // stretch
            case 3: sx = sy = (std::min)(static_cast<float>(width) / iw, static_cast<float>(height) / ih); break;  // fit
            default: sx = sy = (std::max)(static_cast<float>(width) / iw, static_cast<float>(height) / ih); break;  // fill, span
            }
            const UINT dw = (std::max)(1u, static_cast<UINT>(iw * sx * scale + 0.5f)), dh = (std::max)(1u, static_cast<UINT>(ih * sy * scale + 0.5f));
            ComPtr<IWICBitmapScaler> scaler;
            ComPtr<IWICFormatConverter> converter;
            std::vector<BYTE> image(static_cast<size_t>(dw) * dh * 4);
            if (SUCCEEDED(canvas->wic->CreateBitmapScaler(&scaler)) &&
                SUCCEEDED(scaler->Initialize(frame.Get(), dw, dh, WICBitmapInterpolationModeFant)) &&
                SUCCEEDED(canvas->wic->CreateFormatConverter(&converter)) &&
                SUCCEEDED(converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                                WICBitmapPaletteTypeCustom)) &&
                SUCCEEDED(converter->CopyPixels(nullptr, dw * 4, static_cast<UINT>(image.size()), image.data()))) {
                // Laid on the background color: centered, or tiled from the top left.
                auto place = [&](int left, int top) {
                    for (int y = (std::max)(top, 0); y < (std::min)(top + static_cast<int>(dh), oh); y++) {
                        for (int x = (std::max)(left, 0); x < (std::min)(left + static_cast<int>(dw), ow); x++) {
                            const BYTE *s = &image[(static_cast<size_t>(y - top) * dw + (x - left)) * 4];
                            BYTE *d = &px[(static_cast<size_t>(y) * ow + x) * 4];
                            const int a = s[3];
                            for (int c = 0; c < 3; c++) d[c] = static_cast<BYTE>(s[c] + d[c] * (255 - a) / 255);
                        }
                    }
                };
                if (position == 1) {
                    for (int top = 0; top < oh; top += static_cast<int>(dh)) for (int left = 0; left < ow; left += static_cast<int>(dw)) place(left, top);
                } else {
                    place((ow - static_cast<int>(dw)) / 2, (oh - static_cast<int>(dh)) / 2);
                }
            } else {
                result = -1;
            }
        } else if (path) {
            result = -1;
        }
        if (result == 0) {
            canvas->wallpaperPlaced = px;
            canvas->wallpaperPlacedKey = key;
        }
        }
        boxBlur(px, ow, oh, static_cast<int>(blur * scale / 2 + 0.5f));
        if (FAILED(canvas->wic->CreateBitmapFromMemory(static_cast<UINT>(ow), static_cast<UINT>(oh), GUID_WICPixelFormat32bppPBGRA,
                                                       static_cast<UINT>(ow) * 4, static_cast<UINT>(px.size()), px.data(), &canvas->wallpaper))) {
            canvas->wallpaper.Reset();
            result = -1;
        }
        canvas->wallpaperScale = static_cast<float>(ow) / width;
    }
    updateTransparency(canvas);
    return result;
}

void sol_canvas_set_wallpaper_origin(SolCanvas *canvas, float x, float y) { canvas->wallpaperOrigin = D2D1::Point2F(x, y); }

void sol_canvas_set_wallpaper_zoom(SolCanvas *canvas, float zoom) { canvas->wallpaperZoom = zoom > 0 ? zoom : 1; }

int32_t sol_image_file_size(SolCanvas *canvas, const uint16_t *path, int32_t *width, int32_t *height) {
    *width = 0;
    *height = 0;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    UINT w = 0, h = 0;
    if (FAILED(canvas->wic->CreateDecoderFromFilename(reinterpret_cast<const wchar_t *>(path), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder)) ||
        FAILED(decoder->GetFrame(0, &frame)) || FAILED(frame->GetSize(&w, &h))) return -1;
    *width = static_cast<int32_t>(w);
    *height = static_cast<int32_t>(h);
    return 0;
}

int32_t sol_canvas_load_image_file(SolCanvas *canvas, const uint16_t *path, int32_t maxSide) {
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    UINT w = 0, h = 0;
    if (FAILED(canvas->wic->CreateDecoderFromFilename(reinterpret_cast<const wchar_t *>(path), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder)) ||
        FAILED(decoder->GetFrame(0, &frame)) || FAILED(frame->GetSize(&w, &h)) || w == 0 || h == 0) return -1;
    const float shrink = (std::min)(1.0f, static_cast<float>(maxSide) / static_cast<float>((std::max)(w, h)));
    const UINT sw = (std::max)(1u, static_cast<UINT>(w * shrink)), sh = (std::max)(1u, static_cast<UINT>(h * shrink));
    ComPtr<IWICBitmapScaler> scaler;
    ComPtr<IWICFormatConverter> converter;
    ComPtr<IWICBitmap> copy;
    if (FAILED(canvas->wic->CreateBitmapScaler(&scaler)) || FAILED(scaler->Initialize(frame.Get(), sw, sh, WICBitmapInterpolationModeFant)) ||
        FAILED(canvas->wic->CreateFormatConverter(&converter)) ||
        FAILED(converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom)) ||
        FAILED(canvas->wic->CreateBitmapFromSource(converter.Get(), WICBitmapCacheOnLoad, &copy))) return -1;
    canvas->images.push_back(copy);
    canvas->deviceImages.emplace_back();
    return static_cast<int32_t>(canvas->images.size()) - 1;
}

namespace {
/// A number from a GIF frame's metadata ("/imgdesc/Left", "/grctlext/Delay"…), or `fallback`.
UINT gifNumber(IWICMetadataQueryReader *reader, const wchar_t *name, UINT fallback) {
    if (!reader) return fallback;
    PROPVARIANT value;
    PropVariantInit(&value);
    UINT out = fallback;
    if (SUCCEEDED(reader->GetMetadataByName(name, &value))) {
        if (value.vt == VT_UI1) out = value.bVal;
        else if (value.vt == VT_UI2) out = value.uiVal;
        else if (value.vt == VT_UI4) out = value.ulVal;
    }
    PropVariantClear(&value);
    return out;
}
}

int32_t sol_canvas_load_image_frames(SolCanvas *canvas, const uint16_t *path, int32_t maxSide, int32_t *images, int32_t *delays, int32_t capacity) {
    if (capacity < 1) return -1;
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(canvas->wic->CreateDecoderFromFilename(reinterpret_cast<const wchar_t *>(path), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad, &decoder))) return -1;
    UINT count = 0;
    GUID format = {};
    decoder->GetContainerFormat(&format);
    if (FAILED(decoder->GetFrameCount(&count)) || count == 0) return -1;
    if (format != GUID_ContainerFormatGif || count == 1) {
        images[0] = sol_canvas_load_image_file(canvas, path, maxSide);
        delays[0] = 0;
        return images[0] < 0 ? -1 : 1;
    }
    // The GIF's own canvas; each frame is drawn onto it at its offset and then disposed of as it says.
    ComPtr<IWICMetadataQueryReader> top;
    decoder->GetMetadataQueryReader(&top);
    UINT W = gifNumber(top.Get(), L"/logscrdesc/Width", 0), H = gifNumber(top.Get(), L"/logscrdesc/Height", 0);
    if (W == 0 || H == 0) {
        ComPtr<IWICBitmapFrameDecode> first;
        if (FAILED(decoder->GetFrame(0, &first)) || FAILED(first->GetSize(&W, &H))) return -1;
    }
    if (W > 4096 || H > 4096) return -1;
    const float shrink = (std::min)(1.0f, static_cast<float>(maxSide) / static_cast<float>((std::max)(W, H)));
    const UINT sw = (std::max)(1u, static_cast<UINT>(W * shrink)), sh = (std::max)(1u, static_cast<UINT>(H * shrink));
    std::vector<BYTE> screen(static_cast<size_t>(W) * H * 4, 0), saved;
    int32_t made = 0;
    for (UINT i = 0; i < count && made < capacity; i++) {
        ComPtr<IWICBitmapFrameDecode> frame;
        ComPtr<IWICFormatConverter> converter;
        UINT fw = 0, fh = 0;
        if (FAILED(decoder->GetFrame(i, &frame)) || FAILED(frame->GetSize(&fw, &fh))) break;
        ComPtr<IWICMetadataQueryReader> meta;
        frame->GetMetadataQueryReader(&meta);
        const UINT left = gifNumber(meta.Get(), L"/imgdesc/Left", 0), topY = gifNumber(meta.Get(), L"/imgdesc/Top", 0);
        const UINT delay = gifNumber(meta.Get(), L"/grctlext/Delay", 10), disposal = gifNumber(meta.Get(), L"/grctlext/Disposal", 0);
        std::vector<BYTE> pixels(static_cast<size_t>(fw) * fh * 4);
        if (FAILED(canvas->wic->CreateFormatConverter(&converter)) ||
            FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom)) ||
            FAILED(converter->CopyPixels(nullptr, fw * 4, static_cast<UINT>(pixels.size()), pixels.data()))) break;
        if (disposal == 3) saved = screen;
        for (UINT y = 0; y < fh && topY + y < H; y++) {
            for (UINT x = 0; x < fw && left + x < W; x++) {
                const BYTE *p = &pixels[(static_cast<size_t>(y) * fw + x) * 4];
                if (p[3] == 0) continue;
                std::copy(p, p + 4, &screen[(static_cast<size_t>(topY + y) * W + left + x) * 4]);
            }
        }
        // This frame as shown: the whole canvas, shrunk to fit.
        ComPtr<IWICBitmap> full;
        ComPtr<IWICBitmapScaler> scaler;
        ComPtr<IWICBitmap> copy;
        if (FAILED(canvas->wic->CreateBitmapFromMemory(W, H, GUID_WICPixelFormat32bppPBGRA, W * 4, static_cast<UINT>(screen.size()), screen.data(), &full)) ||
            FAILED(canvas->wic->CreateBitmapScaler(&scaler)) || FAILED(scaler->Initialize(full.Get(), sw, sh, WICBitmapInterpolationModeFant)) ||
            FAILED(canvas->wic->CreateBitmapFromSource(scaler.Get(), WICBitmapCacheOnLoad, &copy))) break;
        canvas->images.push_back(copy);
        canvas->deviceImages.emplace_back();
        images[made] = static_cast<int32_t>(canvas->images.size()) - 1;
        // Browsers show a delay under 20 ms as 100 ms.
        delays[made] = delay < 2 ? 100 : static_cast<int32_t>(delay) * 10;
        made++;
        if (disposal == 2) {
            for (UINT y = 0; y < fh && topY + y < H; y++) {
                std::fill_n(&screen[(static_cast<size_t>(topY + y) * W + left) * 4], static_cast<size_t>((std::min)(fw, W - left)) * 4, BYTE(0));
            }
        } else if (disposal == 3 && !saved.empty()) {
            screen = saved;
        }
    }
    return made > 0 ? made : -1;
}

void sol_canvas_fill_rounded_image(SolCanvas *canvas, int32_t image, float x, float y, float width, float height, float radius,
                                   float ix, float iy, float iw, float ih) {
    if (image < 0 || image >= static_cast<int32_t>(canvas->images.size()) || !canvas->images[static_cast<size_t>(image)]) return;
    auto &device = canvas->deviceImages[static_cast<size_t>(image)];
    if (!device && FAILED(canvas->target->CreateBitmapFromWicBitmap(canvas->images[static_cast<size_t>(image)].Get(), &device))) return;
    ComPtr<ID2D1BitmapBrush> brush;
    auto props = D2D1::BitmapBrushProperties(D2D1_EXTEND_MODE_CLAMP, D2D1_EXTEND_MODE_CLAMP, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
    if (FAILED(canvas->target->CreateBitmapBrush(device.Get(), props, &brush))) return;
    auto size = device->GetSize();
    brush->SetTransform(D2D1::Matrix3x2F::Scale(iw / size.width, ih / size.height) * D2D1::Matrix3x2F::Translation(ix, iy));
    canvas->smooth([&] {
        canvas->target->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(x, y, x + width, y + height), radius, radius), brush.Get());
    });
}

int32_t sol_wallpaper_at(int32_t x, int32_t y, uint16_t *path, int32_t capacity, int32_t *area, int32_t *position, uint32_t *background) {
    path[0] = 0;
    *position = 4;
    *background = 0;
    POINT point = {x, y};
    HMONITOR monitor = MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info = {};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(monitor, &info)) return -1;
    RECT rect = info.rcMonitor;
    std::wstring file;
    ComPtr<IDesktopWallpaper> desktop;
    if (SUCCEEDED(CoCreateInstance(__uuidof(DesktopWallpaper), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&desktop)))) {
        DESKTOP_WALLPAPER_POSITION placed = DWPOS_FILL;
        if (SUCCEEDED(desktop->GetPosition(&placed))) *position = static_cast<int32_t>(placed);
        COLORREF fill = 0;
        if (SUCCEEDED(desktop->GetBackgroundColor(&fill))) *background = (GetRValue(fill) << 16) | (GetGValue(fill) << 8) | GetBValue(fill);
        // The monitor's own picture: the one whose rectangle is this monitor's.
        UINT count = 0;
        if (SUCCEEDED(desktop->GetMonitorDevicePathCount(&count))) {
            for (UINT i = 0; i < count && file.empty(); i++) {
                LPWSTR id = nullptr;
                if (FAILED(desktop->GetMonitorDevicePathAt(i, &id)) || !id) continue;
                RECT r = {};
                if (SUCCEEDED(desktop->GetMonitorRECT(id, &r)) && EqualRect(&r, &rect)) {
                    LPWSTR picture = nullptr;
                    if (SUCCEEDED(desktop->GetWallpaper(id, &picture)) && picture) {
                        file = picture;
                        CoTaskMemFree(picture);
                    }
                }
                CoTaskMemFree(id);
            }
        }
    } else {
        *background = (GetRValue(GetSysColor(COLOR_DESKTOP)) << 16) | (GetGValue(GetSysColor(COLOR_DESKTOP)) << 8) | GetBValue(GetSysColor(COLOR_DESKTOP));
    }
    // A slideshow or Windows Spotlight: the picture showing now, as Windows keeps it.
    if (file.empty() || GetFileAttributesW(file.c_str()) == INVALID_FILE_ATTRIBUTES) {
        wchar_t current[MAX_PATH] = {};
        file = SystemParametersInfoW(SPI_GETDESKWALLPAPER, MAX_PATH, current, 0) ? current : L"";
    }
    // Spanned, one picture covers every monitor.
    if (*position == DWPOS_SPAN) {
        rect = {GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN), 0, 0};
        rect.right = rect.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
        rect.bottom = rect.top + GetSystemMetrics(SM_CYVIRTUALSCREEN);
    }
    area[0] = rect.left;
    area[1] = rect.top;
    area[2] = rect.right - rect.left;
    area[3] = rect.bottom - rect.top;
    if (file.size() + 1 > static_cast<size_t>(capacity)) return -1;
    for (size_t i = 0; i <= file.size(); i++) path[i] = i < file.size() ? file[i] : 0;
    return 0;
}

void sol_window_set_backdrop(void *hwnd, int32_t transparent, int32_t blur) {
    HWND window = static_cast<HWND>(hwnd);
    bool blurred = transparent && blur;
    // Not the system backdrop (DWMWA_SYSTEMBACKDROP_TYPE): it only shows where the frame is extended into the window, and
    // the extended frame brings Windows' own caption buttons with it, over Solanum's. The frame stays where it is.
    MARGINS margins = {0, 0, 0, 0};
    DwmExtendFrameIntoClientArea(window, &margins);
    int none = 1;
    DwmSetWindowAttribute(window, 38, &none, sizeof(none));
    // The blur: the window's accent (19 is WCA_ACCENT_POLICY; 3 blurs behind, 0 is off), which blurs what's behind the
    // whole window, honors its alpha, and stays while the window is in the background, as the Mac's does.
    struct AccentPolicy { int state; int flags; uint32_t gradient; int animation; };
    struct CompositionData { int attribute; void *data; SIZE_T size; };
    using SetComposition = BOOL(WINAPI *)(HWND, CompositionData *);
    static auto setComposition = reinterpret_cast<SetComposition>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetWindowCompositionAttribute"));
    if (setComposition) {
        AccentPolicy accent = {blurred ? 3 : 0, 0, 0, 0};
        CompositionData data = {19, &accent, sizeof(accent)};
        setComposition(window, &data);
    }
    // See-through without blur: an empty blur region is what makes the system honor the window's alpha.
    DWM_BLURBEHIND behind = {};
    behind.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
    behind.fEnable = transparent && !blur;
    HRGN empty = CreateRectRgn(0, 0, -1, -1);
    behind.hRgnBlur = empty;
    DwmEnableBlurBehindWindow(window, &behind);
    DeleteObject(empty);
}

void sol_canvas_fill_gradient(SolCanvas *canvas, float x, float y, float width, float height, uint32_t top, uint32_t bottom) {
    D2D1_GRADIENT_STOP stops[2] = {{0, color(top, canvas->opacity)}, {1, color(bottom, canvas->opacity)}};
    ComPtr<ID2D1GradientStopCollection> collection;
    if (FAILED(canvas->target->CreateGradientStopCollection(stops, 2, &collection))) return;
    ComPtr<ID2D1LinearGradientBrush> gradient;
    auto line = D2D1::LinearGradientBrushProperties(D2D1::Point2F(x, y), D2D1::Point2F(x, y + height));
    if (FAILED(canvas->target->CreateLinearGradientBrush(line, collection.Get(), &gradient))) return;
    backdrop(canvas, gradient.Get(), [&](ID2D1Brush *b) { canvas->target->FillRectangle(D2D1::RectF(x, y, x + width, y + height), b); });
}

void sol_canvas_fill_linear(SolCanvas *canvas, float x, float y, float width, float height, float radius, float x0, float y0,
                            float x1, float y1, const uint32_t *colors, const float *alphas, const float *positions, int32_t count) {
    if (count < 2 || count > 16) return;
    D2D1_GRADIENT_STOP stops[16];
    for (int32_t i = 0; i < count; i++) stops[i] = {positions[i], color(colors[i], alphas[i])};
    ComPtr<ID2D1GradientStopCollection> collection;
    if (FAILED(canvas->target->CreateGradientStopCollection(stops, count, &collection))) return;
    ComPtr<ID2D1LinearGradientBrush> gradient;
    auto line = D2D1::LinearGradientBrushProperties(D2D1::Point2F(x0, y0), D2D1::Point2F(x1, y1));
    if (FAILED(canvas->target->CreateLinearGradientBrush(line, collection.Get(), &gradient))) return;
    canvas->smooth([&] {
        if (radius > 0) {
            canvas->target->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(x, y, x + width, y + height), radius, radius), gradient.Get());
        } else {
            canvas->target->FillRectangle(D2D1::RectF(x, y, x + width, y + height), gradient.Get());
        }
    });
}

void sol_canvas_fill_rounded(SolCanvas *canvas, float x, float y, float width, float height, float radius, uint32_t rgb, float alpha) {
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->smooth([&] {
        canvas->target->FillRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(x, y, x + width, y + height), radius, radius), canvas->brush.Get());
    });
}

void sol_canvas_stroke_rounded(SolCanvas *canvas, float x, float y, float width, float height, float radius, uint32_t rgb, float alpha, float thickness) {
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->smooth([&] {
        canvas->target->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(x, y, x + width, y + height), radius, radius), canvas->brush.Get(), thickness);
    });
}

void sol_canvas_stroke_rounded_dashed(SolCanvas *canvas, float x, float y, float width, float height, float radius, uint32_t rgb, float alpha,
                                     float thickness, float dash, float gap) {
    // Dashes are given in units of the line's thickness.
    const float pattern[2] = {dash / thickness, gap / thickness};
    ComPtr<ID2D1StrokeStyle> style;
    auto props = D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_FLAT, D2D1_LINE_JOIN_ROUND, 10,
                                             D2D1_DASH_STYLE_CUSTOM, 0);
    if (FAILED(canvas->d2d->CreateStrokeStyle(props, pattern, 2, &style))) return;
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->smooth([&] {
        canvas->target->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(x, y, x + width, y + height), radius, radius), canvas->brush.Get(), thickness,
                                             style.Get());
    });
}

void sol_canvas_fill_ellipse(SolCanvas *canvas, float cx, float cy, float rx, float ry, uint32_t rgb, float alpha) {
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->smooth([&] { canvas->target->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), rx, ry), canvas->brush.Get()); });
}

namespace {

/// Reads SVG path data (the `d` of a <path>): moves, lines, curves and arcs, absolute and relative, into a sink.
/// Arcs go in as Direct2D's own arc segments, which take the same endpoint form as SVG's.
class SvgPathReader {
public:
    explicit SvgPathReader(const char *d) : p(d) {}

    bool read(ID2D1GeometrySink *sink) {
        char command = 0;
        D2D1_POINT_2F current = {0, 0}, start = {0, 0}, lastControl = {0, 0};
        bool open = false, hadCurve = false;
        auto close = [&](bool closed) {
            if (open) sink->EndFigure(closed ? D2D1_FIGURE_END_CLOSED : D2D1_FIGURE_END_OPEN);
            open = false;
        };
        auto begin = [&] {
            if (!open) { sink->BeginFigure(current, D2D1_FIGURE_BEGIN_FILLED); open = true; }
        };
        while (true) {
            skip();
            if (!*p) break;
            if (isalpha(static_cast<unsigned char>(*p))) {
                command = *p++;
            } else if (!command) {
                return false;
            }
            const bool rel = islower(static_cast<unsigned char>(command)) != 0;
            const float ox = rel ? current.x : 0, oy = rel ? current.y : 0;
            bool curve = false;
            switch (toupper(static_cast<unsigned char>(command))) {
            case 'M': {
                float x, y;
                if (!number(x) || !number(y)) return false;
                close(false);
                current = start = {ox + x, oy + y};
                begin();
                // Further pairs after a move are lines.
                command = rel ? 'l' : 'L';
                break;
            }
            case 'L': {
                float x, y;
                if (!number(x) || !number(y)) return false;
                begin();
                current = {ox + x, oy + y};
                sink->AddLine(current);
                break;
            }
            case 'H': {
                float x;
                if (!number(x)) return false;
                begin();
                current = {ox + x, current.y};
                sink->AddLine(current);
                break;
            }
            case 'V': {
                float y;
                if (!number(y)) return false;
                begin();
                current = {current.x, oy + y};
                sink->AddLine(current);
                break;
            }
            case 'C': {
                float a, b, c, e, f, g;
                if (!number(a) || !number(b) || !number(c) || !number(e) || !number(f) || !number(g)) return false;
                begin();
                D2D1_POINT_2F c1 = {ox + a, oy + b}, c2 = {ox + c, oy + e}, end = {ox + f, oy + g};
                sink->AddBezier(D2D1::BezierSegment(c1, c2, end));
                lastControl = c2;
                current = end;
                curve = true;
                break;
            }
            case 'S': {
                float c, e, f, g;
                if (!number(c) || !number(e) || !number(f) || !number(g)) return false;
                begin();
                D2D1_POINT_2F c1 = hadCurve ? D2D1::Point2F(2 * current.x - lastControl.x, 2 * current.y - lastControl.y) : current;
                D2D1_POINT_2F c2 = {ox + c, oy + e}, end = {ox + f, oy + g};
                sink->AddBezier(D2D1::BezierSegment(c1, c2, end));
                lastControl = c2;
                current = end;
                curve = true;
                break;
            }
            case 'A': {
                float rx, ry, rotation, x, y;
                bool large, sweep;
                if (!number(rx) || !number(ry) || !number(rotation) || !flag(large) || !flag(sweep) || !number(x) || !number(y)) return false;
                begin();
                D2D1_POINT_2F end = {ox + x, oy + y};
                if (rx == 0 || ry == 0) {
                    sink->AddLine(end);
                } else {
                    // With y down, SVG's positive-angle sweep turns clockwise on screen.
                    sink->AddArc(D2D1::ArcSegment(end, D2D1::SizeF(fabsf(rx), fabsf(ry)), rotation,
                                                  sweep ? D2D1_SWEEP_DIRECTION_CLOCKWISE : D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE,
                                                  large ? D2D1_ARC_SIZE_LARGE : D2D1_ARC_SIZE_SMALL));
                }
                current = end;
                break;
            }
            case 'Z':
                close(true);
                current = start;
                break;
            default:
                return false;
            }
            hadCurve = curve;
        }
        close(false);
        return true;
    }

private:
    const char *p;

    void skip() { while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\t' || *p == '\r') ++p; }

    /// A number as SVG writes them, run together where it can be: "-.5157-4.9108" is two, as is "1.5.5".
    bool number(float &out) {
        skip();
        const char *s = p;
        if (*p == '+' || *p == '-') ++p;
        bool digits = false, dot = false;
        while (isdigit(static_cast<unsigned char>(*p)) || (*p == '.' && !dot)) {
            if (*p == '.') dot = true; else digits = true;
            ++p;
        }
        if (!digits) { p = s; return false; }
        if (*p == 'e' || *p == 'E') {
            const char *e = p + 1;
            if (*e == '+' || *e == '-') ++e;
            if (isdigit(static_cast<unsigned char>(*e))) { p = e; while (isdigit(static_cast<unsigned char>(*p))) ++p; }
        }
        out = static_cast<float>(strtod(std::string(s, p).c_str(), nullptr));
        return true;
    }

    /// An arc's flag: a single 0 or 1, which may run straight into the next number.
    bool flag(bool &out) {
        skip();
        if (*p != '0' && *p != '1') return false;
        out = *p++ == '1';
        return true;
    }
};

}  // namespace

void sol_canvas_fill_svg_path(SolCanvas *canvas, const char *d, float x, float y, float scale, uint32_t rgb, float alpha) {
    if (!d) return;
    auto &geometry = canvas->svgPaths[d];
    if (!geometry) {
        ComPtr<ID2D1PathGeometry> made;
        ComPtr<ID2D1GeometrySink> sink;
        if (FAILED(canvas->d2d->CreatePathGeometry(&made)) || FAILED(made->Open(&sink))) return;
        sink->SetFillMode(D2D1_FILL_MODE_WINDING);
        const bool read = SvgPathReader(d).read(sink.Get());
        if (FAILED(sink->Close()) || !read) return;
        geometry = made;
    }
    D2D1_MATRIX_3X2_F before;
    canvas->target->GetTransform(&before);
    canvas->target->SetTransform(D2D1::Matrix3x2F::Scale(scale, scale) * D2D1::Matrix3x2F::Translation(x, y) * before);
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->smooth([&] { canvas->target->FillGeometry(geometry.Get(), canvas->brush.Get()); });
    canvas->target->SetTransform(before);
}

namespace {

/// A path's geometry, made once from its SVG data.
ID2D1PathGeometry *svgGeometry(SolCanvas *canvas, const char *d) {
    auto &geometry = canvas->svgPaths[d];
    if (!geometry) {
        ComPtr<ID2D1PathGeometry> made;
        ComPtr<ID2D1GeometrySink> sink;
        if (FAILED(canvas->d2d->CreatePathGeometry(&made)) || FAILED(made->Open(&sink))) return nullptr;
        sink->SetFillMode(D2D1_FILL_MODE_WINDING);
        const bool read = SvgPathReader(d).read(sink.Get());
        if (FAILED(sink->Close()) || !read) return nullptr;
        geometry = made;
    }
    return geometry.Get();
}

/// A polygon or polyline through `count` points (x, y, x, y, …), made fresh.
bool polygon(SolCanvas *canvas, const float *xy, int32_t count, bool closed, bool filled, ComPtr<ID2D1PathGeometry> &made) {
    ComPtr<ID2D1GeometrySink> sink;
    if (count < 2 || FAILED(canvas->d2d->CreatePathGeometry(&made)) || FAILED(made->Open(&sink))) return false;
    sink->BeginFigure(D2D1::Point2F(xy[0], xy[1]), filled ? D2D1_FIGURE_BEGIN_FILLED : D2D1_FIGURE_BEGIN_HOLLOW);
    for (int32_t i = 1; i < count; ++i) sink->AddLine(D2D1::Point2F(xy[i * 2], xy[i * 2 + 1]));
    sink->EndFigure(closed ? D2D1_FIGURE_END_CLOSED : D2D1_FIGURE_END_OPEN);
    return SUCCEEDED(sink->Close());
}

ID2D1StrokeStyle *roundStroke(SolCanvas *canvas) {
    if (!canvas->roundStroke) {
        auto props = D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_LINE_JOIN_ROUND);
        canvas->d2d->CreateStrokeStyle(props, nullptr, 0, &canvas->roundStroke);
    }
    return canvas->roundStroke.Get();
}

}  // namespace

void sol_canvas_stroke_svg_path(SolCanvas *canvas, const char *d, float x, float y, float scale, uint32_t rgb, float alpha, float width) {
    if (!d) return;
    auto *geometry = svgGeometry(canvas, d);
    if (!geometry) return;
    D2D1_MATRIX_3X2_F before;
    canvas->target->GetTransform(&before);
    canvas->target->SetTransform(D2D1::Matrix3x2F::Scale(scale, scale) * D2D1::Matrix3x2F::Translation(x, y) * before);
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->smooth([&] { canvas->target->DrawGeometry(geometry, canvas->brush.Get(), width, roundStroke(canvas)); });
    canvas->target->SetTransform(before);
}

void sol_canvas_fill_polygon(SolCanvas *canvas, const float *xy, int32_t count, uint32_t rgb, float alpha) {
    ComPtr<ID2D1PathGeometry> shape;
    if (!polygon(canvas, xy, count, true, true, shape)) return;
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->smooth([&] { canvas->target->FillGeometry(shape.Get(), canvas->brush.Get()); });
}

void sol_canvas_stroke_polyline(SolCanvas *canvas, const float *xy, int32_t count, int32_t closed, uint32_t rgb, float alpha, float width) {
    ComPtr<ID2D1PathGeometry> shape;
    if (!polygon(canvas, xy, count, closed != 0, false, shape)) return;
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->smooth([&] { canvas->target->DrawGeometry(shape.Get(), canvas->brush.Get(), width, roundStroke(canvas)); });
}

void sol_canvas_fill_radial(SolCanvas *canvas, float cx, float cy, float rx, float ry, uint32_t inner, float innerAlpha, uint32_t outer, float outerAlpha) {
    D2D1_GRADIENT_STOP stops[2] = {{0, color(inner, innerAlpha)}, {1, color(outer, outerAlpha)}};
    ComPtr<ID2D1GradientStopCollection> collection;
    if (FAILED(canvas->target->CreateGradientStopCollection(stops, 2, &collection))) return;
    ComPtr<ID2D1RadialGradientBrush> radial;
    if (FAILED(canvas->target->CreateRadialGradientBrush(
            D2D1::RadialGradientBrushProperties(D2D1::Point2F(cx, cy), D2D1::Point2F(0, 0), rx, ry), collection.Get(), &radial))) return;
    canvas->smooth([&] { canvas->target->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), rx, ry), radial.Get()); });
}

void sol_canvas_fill_rect_radial(SolCanvas *canvas, float x, float y, float width, float height, float cx, float cy, float rx, float ry,
                                 uint32_t inner, uint32_t outer) {
    D2D1_GRADIENT_STOP stops[2] = {{0, color(inner)}, {1, color(outer)}};
    ComPtr<ID2D1GradientStopCollection> collection;
    if (FAILED(canvas->target->CreateGradientStopCollection(stops, 2, &collection))) return;
    ComPtr<ID2D1RadialGradientBrush> radial;
    if (FAILED(canvas->target->CreateRadialGradientBrush(
            D2D1::RadialGradientBrushProperties(D2D1::Point2F(cx, cy), D2D1::Point2F(0, 0), rx, ry), collection.Get(), &radial))) return;
    canvas->target->FillRectangle(D2D1::RectF(x, y, x + width, y + height), radial.Get());
}

int32_t sol_canvas_layer_make(SolCanvas *canvas, float width, float height) {
    if (!canvas->target || canvas->savedTarget) return -1;
    ComPtr<ID2D1BitmapRenderTarget> layer;
    if (FAILED(canvas->target->CreateCompatibleRenderTarget(D2D1::SizeF(width, height), &layer))) return -1;
    canvas->layers.push_back(layer);
    return static_cast<int32_t>(canvas->layers.size()) - 1;
}

void sol_canvas_layer_free(SolCanvas *canvas, int32_t layer) {
    if (layer >= 0 && layer < static_cast<int32_t>(canvas->layers.size())) canvas->layers[static_cast<size_t>(layer)].Reset();
}

int32_t sol_canvas_layer_alive(SolCanvas *canvas, int32_t layer) {
    return layer >= 0 && layer < static_cast<int32_t>(canvas->layers.size()) && canvas->layers[static_cast<size_t>(layer)] ? 1 : 0;
}

int32_t sol_canvas_layer_begin(SolCanvas *canvas, int32_t layer, int32_t clear) {
    if (!sol_canvas_layer_alive(canvas, layer) || canvas->savedTarget) return 0;
    auto &target = canvas->layers[static_cast<size_t>(layer)];
    canvas->savedTarget = canvas->target;
    canvas->target = target;
    target->BeginDraw();
    if (clear) target->Clear(D2D1::ColorF(0, 0, 0, 0));
    target->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
    return 1;
}

void sol_canvas_layer_end(SolCanvas *canvas) {
    if (!canvas->savedTarget) return;
    canvas->target->EndDraw();
    canvas->target = canvas->savedTarget;
    canvas->savedTarget.Reset();
}

void sol_canvas_layer_draw(SolCanvas *canvas, int32_t layer, float x, float y, float width, float height, float alpha) {
    if (!sol_canvas_layer_alive(canvas, layer)) return;
    ComPtr<ID2D1Bitmap> bitmap;
    if (FAILED(canvas->layers[static_cast<size_t>(layer)]->GetBitmap(&bitmap))) return;
    canvas->target->DrawBitmap(bitmap.Get(), D2D1::RectF(x, y, x + width, y + height), alpha, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
}

int32_t sol_canvas_add_font(SolCanvas *canvas, const uint8_t *data, int32_t length) {
    ComPtr<IDWriteFactory5> factory;
    if (FAILED(canvas->dwrite.As(&factory))) return 0;
    ComPtr<IDWriteInMemoryFontFileLoader> loader;
    if (FAILED(factory->CreateInMemoryFontFileLoader(&loader)) || FAILED(factory->RegisterFontFileLoader(loader.Get()))) return 0;
    ComPtr<IDWriteFontFile> file;
    if (FAILED(loader->CreateInMemoryFontFileReference(factory.Get(), data, static_cast<UINT32>(length), nullptr, &file))) return 0;
    ComPtr<IDWriteFontSetBuilder1> builder;
    if (FAILED(factory->CreateFontSetBuilder(&builder)) || FAILED(builder->AddFontFile(file.Get()))) return 0;
    ComPtr<IDWriteFontSet> set;
    if (FAILED(builder->CreateFontSet(&set))) return 0;
    ComPtr<IDWriteFontCollection1> collection;
    if (FAILED(factory->CreateFontCollectionFromFontSet(set.Get(), &collection))) return 0;
    canvas->privateFonts = collection;
    canvas->privateFormats.clear();
    return 1;
}

float sol_canvas_text_in(SolCanvas *canvas, const uint16_t *family, float x, float y, float width, const uint16_t *text, int32_t length,
                         float pixels, float lineSpacing, uint32_t rgb, float alpha, int32_t shown, int32_t measureOnly, float *usedWidth) {
    if (usedWidth) *usedWidth = 0;
    if (length <= 0 || width <= 0 || !family) return 0;
    std::wstring name(reinterpret_cast<const wchar_t *>(family));
    auto key = std::make_pair(name, static_cast<int>(pixels * 10));
    auto &format = canvas->privateFormats[key];
    if (!format) {
        // In the font that came with Solanum, else the system's monospaced one.
        if (FAILED(canvas->dwrite->CreateTextFormat(name.c_str(), canvas->privateFonts.Get(), DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                                                    DWRITE_FONT_STRETCH_NORMAL, pixels, L"", &format))) return 0;
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
    }
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(canvas->dwrite->CreateTextLayout(reinterpret_cast<const WCHAR *>(text), static_cast<UINT32>(length), format.Get(), width, 10000, &layout))) return 0;
    if (lineSpacing > 0) {
        // The font's own line height, plus `lineSpacing`.
        ComPtr<IDWriteTextLayout> probe;
        DWRITE_TEXT_METRICS one = {};
        if (SUCCEEDED(canvas->dwrite->CreateTextLayout(L"M", 1, format.Get(), 1000, 1000, &probe))) probe->GetMetrics(&one);
        if (one.height > 0) layout->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, one.height + lineSpacing, (one.height + lineSpacing) * 0.8f);
    }
    DWRITE_TEXT_METRICS metrics = {};
    layout->GetMetrics(&metrics);
    if (usedWidth) *usedWidth = metrics.widthIncludingTrailingWhitespace;
    if (!measureOnly) {
        // Laid out whole, so lines don't rewrap as more shows; what isn't shown yet is drawn in nothing.
        ComPtr<ID2D1SolidColorBrush> clear;
        if (shown < length && SUCCEEDED(canvas->target->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0), &clear))) {
            layout->SetDrawingEffect(clear.Get(), DWRITE_TEXT_RANGE{static_cast<UINT32>(shown < 0 ? 0 : shown), static_cast<UINT32>(length)});
        }
        canvas->brush->SetColor(color(rgb, alpha));
        canvas->target->DrawTextLayout(D2D1::Point2F(x, y), layout.Get(), canvas->brush.Get());
    }
    return metrics.height;
}

void sol_canvas_line(SolCanvas *canvas, float x1, float y1, float x2, float y2, uint32_t rgb, float alpha, float thickness) {
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->smooth([&] { canvas->target->DrawLine(D2D1::Point2F(x1, y1), D2D1::Point2F(x2, y2), canvas->brush.Get(), thickness); });
}

void sol_canvas_push_clip(SolCanvas *canvas, float x, float y, float width, float height) {
    canvas->target->PushAxisAlignedClip(D2D1::RectF(x, y, x + width, y + height), D2D1_ANTIALIAS_MODE_ALIASED);
}

void sol_canvas_pop_clip(SolCanvas *canvas) { canvas->target->PopAxisAlignedClip(); }

void sol_canvas_push_opacity(SolCanvas *canvas, float opacity) {
    // A layer without a size grows to what's drawn into it (Windows 8 and later).
    canvas->target->PushLayer(D2D1::LayerParameters(D2D1::InfiniteRect(), nullptr, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
                                                     D2D1::IdentityMatrix(), opacity), nullptr);
}

void sol_canvas_pop_opacity(SolCanvas *canvas) { canvas->target->PopLayer(); }

void sol_canvas_draw_label(SolCanvas *canvas, float x, float y, float width, float height, const uint16_t *text, int32_t length,
                           float pixels, int32_t semibold, uint32_t rgb, float alpha) {
    auto *format = canvas->labelFormat(pixels, semibold);
    if (!format || length <= 0 || width <= 0) return;
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->target->DrawText(reinterpret_cast<const WCHAR *>(text), static_cast<UINT32>(length), format,
                             D2D1::RectF(x, y, x + width, y + height), canvas->brush.Get(), D2D1_DRAW_TEXT_OPTIONS_CLIP);
}

float sol_canvas_measure_label(SolCanvas *canvas, const uint16_t *text, int32_t length, float pixels, int32_t semibold) {
    auto *format = canvas->labelFormat(pixels, semibold);
    if (!format || length <= 0) return 0;
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(canvas->dwrite->CreateTextLayout(reinterpret_cast<const WCHAR *>(text), static_cast<UINT32>(length), format, 10000, 1000, &layout))) return 0;
    DWRITE_TEXT_METRICS metrics = {};
    if (FAILED(layout->GetMetrics(&metrics))) return 0;
    return metrics.widthIncludingTrailingWhitespace;
}

float sol_canvas_paragraph(SolCanvas *canvas, float x, float y, float width, const uint16_t *text, int32_t length, float pixels,
                           int32_t semibold, uint32_t rgb, float alpha, int32_t measureOnly) {
    auto *format = canvas->paragraphFormat(pixels, semibold);
    if (!format || length <= 0 || width <= 0) return 0;
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(canvas->dwrite->CreateTextLayout(reinterpret_cast<const WCHAR *>(text), static_cast<UINT32>(length), format, width, 10000, &layout))) return 0;
    DWRITE_TEXT_METRICS metrics = {};
    layout->GetMetrics(&metrics);
    if (!measureOnly) {
        canvas->brush->SetColor(color(rgb, alpha));
        canvas->target->DrawTextLayout(D2D1::Point2F(x, y), layout.Get(), canvas->brush.Get());
    }
    return metrics.height;
}

void sol_canvas_draw_icon(SolCanvas *canvas, float x, float y, float width, float height, uint16_t glyph, float pixels, uint32_t rgb, float alpha) {
    auto *format = canvas->iconFormat(pixels);
    if (!format) return;
    canvas->brush->SetColor(color(rgb, alpha));
    WCHAR text = static_cast<WCHAR>(glyph);
    canvas->target->DrawText(&text, 1, format, D2D1::RectF(x, y, x + width, y + height), canvas->brush.Get());
}

int32_t sol_canvas_load_image(SolCanvas *canvas, const uint8_t *png, int32_t length) {
    ComPtr<IWICStream> stream;
    if (FAILED(canvas->wic->CreateStream(&stream))) return -1;
    if (FAILED(stream->InitializeFromMemory(const_cast<BYTE *>(png), static_cast<DWORD>(length)))) return -1;
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(canvas->wic->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder))) return -1;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, &frame))) return -1;
    ComPtr<IWICFormatConverter> converter;
    if (FAILED(canvas->wic->CreateFormatConverter(&converter))) return -1;
    if (FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) return -1;
    // Copied out, because the stream only borrows the PNG's bytes.
    ComPtr<IWICBitmap> copy;
    if (FAILED(canvas->wic->CreateBitmapFromSource(converter.Get(), WICBitmapCacheOnLoad, &copy))) return -1;
    canvas->images.push_back(copy);
    canvas->deviceImages.emplace_back();
    return static_cast<int32_t>(canvas->images.size()) - 1;
}

int32_t sol_canvas_load_rgba(SolCanvas *canvas, const uint8_t *rgba, int32_t width, int32_t height, uint32_t tint) {
    if (!rgba || width <= 0 || height <= 0) return -1;
    // Direct2D wants blue first.
    std::vector<BYTE> bgra(static_cast<size_t>(width) * height * 4);
    const bool tinted = tint != 0xFFFFFFFF;
    const float tr = ((tint >> 16) & 0xFF) / 255.0f, tg = ((tint >> 8) & 0xFF) / 255.0f, tb = (tint & 0xFF) / 255.0f;
    for (size_t i = 0; i < bgra.size(); i += 4) {
        if (tinted) {
            // Every pixel in the tint, keeping its coverage.
            const float a = rgba[i + 3];
            bgra[i] = static_cast<BYTE>(tb * a + 0.5f);
            bgra[i + 1] = static_cast<BYTE>(tg * a + 0.5f);
            bgra[i + 2] = static_cast<BYTE>(tr * a + 0.5f);
        } else {
            bgra[i] = rgba[i + 2];
            bgra[i + 1] = rgba[i + 1];
            bgra[i + 2] = rgba[i];
        }
        bgra[i + 3] = rgba[i + 3];
    }
    ComPtr<IWICBitmap> bitmap;
    if (FAILED(canvas->wic->CreateBitmapFromMemory(static_cast<UINT>(width), static_cast<UINT>(height), GUID_WICPixelFormat32bppPBGRA,
                                                   static_cast<UINT>(width) * 4, static_cast<UINT>(bgra.size()), bgra.data(), &bitmap))) return -1;
    canvas->images.push_back(bitmap);
    canvas->deviceImages.emplace_back();
    return static_cast<int32_t>(canvas->images.size()) - 1;
}

int32_t sol_canvas_decode_png(SolCanvas *canvas, const uint8_t *png, int32_t length, uint8_t **rgba, int32_t *width, int32_t *height) {
    *rgba = nullptr;
    ComPtr<IWICStream> stream;
    if (FAILED(canvas->wic->CreateStream(&stream)) || FAILED(stream->InitializeFromMemory(const_cast<BYTE *>(png), static_cast<DWORD>(length)))) return -1;
    ComPtr<IWICBitmapDecoder> decoder;
    if (FAILED(canvas->wic->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder))) return -1;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, &frame))) return -1;
    ComPtr<IWICFormatConverter> converter;
    if (FAILED(canvas->wic->CreateFormatConverter(&converter))) return -1;
    if (FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPRGBA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) return -1;
    UINT w = 0, h = 0;
    converter->GetSize(&w, &h);
    auto *out = static_cast<uint8_t *>(malloc(static_cast<size_t>(w) * h * 4));
    if (!out) return -1;
    if (FAILED(converter->CopyPixels(nullptr, w * 4, w * h * 4, out))) { free(out); return -1; }
    *rgba = out;
    *width = static_cast<int32_t>(w);
    *height = static_cast<int32_t>(h);
    return 0;
}

void sol_canvas_free(void *memory) { free(memory); }

int32_t sol_canvas_load_svg(SolCanvas *canvas, const uint8_t *data, int32_t length) {
    if (!data || length <= 0) return -1;
    canvas->svgData.emplace_back(data, data + length);
    return static_cast<int32_t>(canvas->svgData.size()) - 1;
}

int32_t sol_canvas_draw_svg(SolCanvas *canvas, int32_t svg, float x, float y, float size) {
    if (svg < 0 || svg >= static_cast<int32_t>(canvas->svgData.size()) || size < 1) return 0;
    // SVG takes Direct2D 1.3 (Windows 10 1703 and later).
    ComPtr<ID2D1DeviceContext5> dc;
    if (FAILED(canvas->target.As(&dc))) return 0;
    const int px = static_cast<int>(size + 0.5f);
    auto key = std::make_pair(static_cast<int>(svg), px);
    auto found = canvas->svgDocuments.find(key);
    if (found == canvas->svgDocuments.end()) {
        ComPtr<ID2D1SvgDocument> doc;
        const auto &bytes = canvas->svgData[static_cast<size_t>(svg)];
        IStream *stream = SHCreateMemStream(bytes.data(), static_cast<UINT>(bytes.size()));
        if (stream) {
            if (FAILED(dc->CreateSvgDocument(stream, D2D1::SizeF(static_cast<float>(px), static_cast<float>(px)), &doc))) doc.Reset();
            stream->Release();
        }
        // Icon files usually say their own size (width="16" height="16"), which Direct2D keeps over the square asked
        // for: they'd draw at 16 real pixels whatever the display's scale. Their drawing is made to fill the square
        // instead, through a viewBox of that size when they haven't one.
        ComPtr<ID2D1SvgElement> root;
        if (doc) doc->GetRoot(&root);
        if (root) {
            D2D1_SVG_LENGTH w = {}, h = {};
            const bool hasW = SUCCEEDED(root->GetAttributeValue(L"width", D2D1_SVG_ATTRIBUTE_POD_TYPE_LENGTH, &w, sizeof(w)));
            const bool hasH = SUCCEEDED(root->GetAttributeValue(L"height", D2D1_SVG_ATTRIBUTE_POD_TYPE_LENGTH, &h, sizeof(h)));
            if (!root->IsAttributeSpecified(L"viewBox", nullptr)) {
                D2D1_SVG_VIEWBOX box = {0, 0, hasW && w.units == D2D1_SVG_LENGTH_UNITS_NUMBER && w.value > 0 ? w.value : 16,
                                        hasH && h.units == D2D1_SVG_LENGTH_UNITS_NUMBER && h.value > 0 ? h.value : 16};
                root->SetAttributeValue(L"viewBox", D2D1_SVG_ATTRIBUTE_POD_TYPE_VIEWBOX, &box, sizeof(box));
            }
            D2D1_SVG_LENGTH full = {100, D2D1_SVG_LENGTH_UNITS_PERCENTAGE};
            root->SetAttributeValue(L"width", D2D1_SVG_ATTRIBUTE_POD_TYPE_LENGTH, &full, sizeof(full));
            root->SetAttributeValue(L"height", D2D1_SVG_ATTRIBUTE_POD_TYPE_LENGTH, &full, sizeof(full));
        }
        found = canvas->svgDocuments.emplace(key, doc).first;
    }
    if (!found->second) return 0;
    D2D1_MATRIX_3X2_F old;
    canvas->target->GetTransform(&old);
    canvas->target->SetTransform(D2D1::Matrix3x2F::Translation(x, y) * old);
    canvas->smooth([&] { dc->DrawSvgDocument(found->second.Get()); });
    canvas->target->SetTransform(old);
    return 1;
}

int32_t sol_canvas_load_icon_font(SolCanvas *canvas, const uint8_t *data, int32_t length) {
    if (!data || length < 4) return -1;
    ComPtr<IDWriteFactory5> factory;
    if (FAILED(canvas->dwrite.As(&factory))) return -1;
    if (!canvas->iconFontLoader) {
        if (FAILED(factory->CreateInMemoryFontFileLoader(&canvas->iconFontLoader)) || FAILED(factory->RegisterFontFileLoader(canvas->iconFontLoader.Get()))) {
            canvas->iconFontLoader.Reset();
            return -1;
        }
    }
    std::vector<uint8_t> bytes(data, data + length);
    // WOFF and WOFF2, as VS Code's themes ship them, unwrapped by DirectWrite itself.
    DWRITE_CONTAINER_TYPE container = factory->AnalyzeContainerType(data, static_cast<UINT32>(length));
    if (container != DWRITE_CONTAINER_TYPE_UNKNOWN) {
        ComPtr<IDWriteFontFileStream> stream;
        if (FAILED(factory->UnpackFontFile(container, data, static_cast<UINT32>(length), &stream))) return -1;
        UINT64 size = 0;
        const void *fragment = nullptr;
        void *context = nullptr;
        if (FAILED(stream->GetFileSize(&size)) || size == 0 || FAILED(stream->ReadFileFragment(&fragment, 0, size, &context))) return -1;
        bytes.assign(static_cast<const uint8_t *>(fragment), static_cast<const uint8_t *>(fragment) + size);
        stream->ReleaseFileFragment(context);
    }
    canvas->iconFontData.push_back(std::move(bytes));
    const auto &kept = canvas->iconFontData.back();
    ComPtr<IDWriteFontFile> file;
    if (FAILED(canvas->iconFontLoader->CreateInMemoryFontFileReference(factory.Get(), kept.data(), static_cast<UINT32>(kept.size()), nullptr, &file))) return -1;
    BOOL supported = FALSE;
    DWRITE_FONT_FILE_TYPE fileType;
    DWRITE_FONT_FACE_TYPE faceType;
    UINT32 faces = 0;
    if (FAILED(file->Analyze(&supported, &fileType, &faceType, &faces)) || !supported) return -1;
    ComPtr<IDWriteFontFace> face;
    IDWriteFontFile *files[] = {file.Get()};
    if (FAILED(canvas->dwrite->CreateFontFace(faceType, 1, files, 0, DWRITE_FONT_SIMULATIONS_NONE, &face))) return -1;
    canvas->iconFaces.push_back(face);
    return static_cast<int32_t>(canvas->iconFaces.size()) - 1;
}

int32_t sol_canvas_draw_icon_glyph(SolCanvas *canvas, int32_t font, uint32_t codepoint, float x, float y, float size, float scale,
                                   uint32_t rgb, float alpha) {
    if (font < 0 || font >= static_cast<int32_t>(canvas->iconFaces.size())) return 0;
    IDWriteFontFace *face = canvas->iconFaces[static_cast<size_t>(font)].Get();
    UINT16 glyph = 0;
    if (FAILED(face->GetGlyphIndices(&codepoint, 1, &glyph)) || glyph == 0) return 0;
    DWRITE_FONT_METRICS fm;
    face->GetMetrics(&fm);
    DWRITE_GLYPH_METRICS gm;
    if (FAILED(face->GetDesignGlyphMetrics(&glyph, 1, &gm, FALSE)) || fm.designUnitsPerEm == 0) return 0;
    // Its ink, in design units: across from its left side bearing, and up from the baseline.
    const float left = static_cast<float>(gm.leftSideBearing);
    const float width = static_cast<float>(static_cast<INT32>(gm.advanceWidth) - gm.leftSideBearing - gm.rightSideBearing);
    const float top = static_cast<float>(gm.verticalOriginY - gm.topSideBearing);
    const float height = static_cast<float>(static_cast<INT32>(gm.advanceHeight) - gm.topSideBearing - gm.bottomSideBearing);
    if (width <= 0 || height <= 0) return 0;
    // VS Code sizes font icons against its 13px UI font, in a 16px square; one bigger than the square is shrunk to fit.
    float em = 13.0f * scale * size / 16.0f;
    float unit = em / fm.designUnitsPerEm;
    const float fit = (std::min)(1.0f, (std::min)(size / (width * unit), size / (height * unit)));
    em *= fit;
    unit *= fit;
    const float originX = x + size / 2 - (left + width / 2) * unit;
    const float baseline = y + size / 2 + (top - height / 2) * unit;
    DWRITE_GLYPH_RUN run = {};
    run.fontFace = face;
    run.fontEmSize = em;
    run.glyphCount = 1;
    run.glyphIndices = &glyph;
    canvas->brush->SetColor(color(rgb, alpha));
    canvas->target->DrawGlyphRun(D2D1::Point2F(originX, baseline), &run, canvas->brush.Get());
    return 1;
}

int32_t sol_download_file(const uint16_t *url, const uint16_t *path) {
    return URLDownloadToFileW(nullptr, reinterpret_cast<const wchar_t *>(url), reinterpret_cast<const wchar_t *>(path), 0, nullptr);
}

void sol_canvas_draw_image(SolCanvas *canvas, int32_t image, float x, float y, float width, float height, float alpha) {
    if (image < 0 || image >= static_cast<int32_t>(canvas->images.size()) || !canvas->images[static_cast<size_t>(image)]) return;
    auto &device = canvas->deviceImages[static_cast<size_t>(image)];
    if (!device && FAILED(canvas->target->CreateBitmapFromWicBitmap(canvas->images[static_cast<size_t>(image)].Get(), &device))) return;
    canvas->target->DrawBitmap(device.Get(), D2D1::RectF(x, y, x + width, y + height), alpha, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
}

void sol_canvas_image_size(SolCanvas *canvas, int32_t image, int32_t *width, int32_t *height) {
    *width = 0;
    *height = 0;
    if (image < 0 || image >= static_cast<int32_t>(canvas->images.size()) || !canvas->images[static_cast<size_t>(image)]) return;
    UINT w = 0, h = 0;
    if (SUCCEEDED(canvas->images[static_cast<size_t>(image)]->GetSize(&w, &h))) {
        *width = static_cast<int32_t>(w);
        *height = static_cast<int32_t>(h);
    }
}

void sol_canvas_free_image(SolCanvas *canvas, int32_t image) {
    if (image < 0 || image >= static_cast<int32_t>(canvas->images.size())) return;
    canvas->images[static_cast<size_t>(image)].Reset();
    canvas->deviceImages[static_cast<size_t>(image)].Reset();
}

int32_t sol_canvas_save_png(SolCanvas *canvas, const uint16_t *path) {
    if (!canvas->bitmap || !canvas->wic) return E_INVALIDARG;
    ComPtr<IWICStream> stream;
    HRESULT hr = canvas->wic->CreateStream(&stream);
    if (FAILED(hr)) return hr;
    hr = stream->InitializeFromFilename(reinterpret_cast<const WCHAR *>(path), GENERIC_WRITE);
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmapEncoder> encoder;
    hr = canvas->wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (FAILED(hr)) return hr;
    hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmapFrameEncode> frame;
    hr = encoder->CreateNewFrame(&frame, nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->Initialize(nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->SetSize(canvas->width, canvas->height);
    if (FAILED(hr)) return hr;
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    hr = frame->SetPixelFormat(&format);
    if (FAILED(hr)) return hr;
    hr = frame->WriteSource(canvas->bitmap.Get(), nullptr);
    if (FAILED(hr)) return hr;
    hr = frame->Commit();
    if (FAILED(hr)) return hr;
    return encoder->Commit();
}

int32_t sol_protect_memory(void *bytes, uint32_t length, int32_t reveal) {
    if (reveal) return CryptUnprotectMemory(bytes, length, CRYPTPROTECTMEMORY_SAME_PROCESS) ? 1 : 0;
    return CryptProtectMemory(bytes, length, CRYPTPROTECTMEMORY_SAME_PROCESS) ? 1 : 0;
}

}  // extern "C"
