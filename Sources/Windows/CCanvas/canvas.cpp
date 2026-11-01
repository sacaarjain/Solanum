#include "canvas.h"

#include <windows.h>
#include <d2d1.h>
#include <dwmapi.h>
#include <dwrite.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cmath>
#include <vector>

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "windowscodecs.lib")

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
    ComPtr<ID2D1SolidColorBrush> brush;

    ComPtr<IDWriteFontFace> faces[4];
    ComPtr<IDWriteTextFormat> formats[4];
    SolMetrics metrics = {};
    float fontPixels = 0;
    float emScale = 0;

    std::vector<UINT16> glyphs;
    std::vector<FLOAT> advances;

    HRESULT createTarget() {
        windowTarget.Reset();
        target.Reset();
        brush.Reset();
        HRESULT hr;
        // 96 DPI makes one Direct2D unit one pixel.
        if (hwnd) {
            auto props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(), 96, 96);
            auto window = D2D1::HwndRenderTargetProperties(hwnd, D2D1::SizeU(width, height));
            hr = d2d->CreateHwndRenderTarget(props, window, &windowTarget);
            if (FAILED(hr)) return hr;
            target = windowTarget;
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
        for (const wchar_t *name : kFontFamilies) {
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
        metrics.cellHeight = std::round((m.ascent + m.descent + m.lineGap) * emScale);
        metrics.baseline = std::round((m.ascent + m.lineGap / 2.0f) * emScale);
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
    HRESULT hr = canvas->createFactories(fontPixels);
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
    canvas->target->Clear(color(background));
    return S_OK;
}

int32_t sol_canvas_end(SolCanvas *canvas) {
    HRESULT hr = canvas->target->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) {
        canvas->target.Reset();
        canvas->windowTarget.Reset();
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

}  // extern "C"
