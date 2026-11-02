import WinSDK

/// Written out because several of the SDK's are macros Swift doesn't import.
enum Win {
    static let WM_DESTROY: UINT = 0x0002, WM_SIZE: UINT = 0x0005, WM_SETFOCUS: UINT = 0x0007, WM_KILLFOCUS: UINT = 0x0008
    static let WM_PAINT: UINT = 0x000F, WM_CLOSE: UINT = 0x0010, WM_ERASEBKGND: UINT = 0x0014
    static let WM_KEYDOWN: UINT = 0x0100, WM_CHAR: UINT = 0x0102, WM_SYSKEYDOWN: UINT = 0x0104, WM_SYSCHAR: UINT = 0x0106
    static let WM_TIMER: UINT = 0x0113
    static let WM_SETCURSOR: UINT = 0x0020, WM_NCCALCSIZE: UINT = 0x0083, WM_NCHITTEST: UINT = 0x0084
    static let WM_NCMOUSEMOVE: UINT = 0x00A0, WM_NCLBUTTONDOWN: UINT = 0x00A1, WM_NCLBUTTONUP: UINT = 0x00A2
    static let WM_MOUSELEAVE: UINT = 0x02A3, WM_NCMOUSELEAVE: UINT = 0x02A2
    static let WM_MOUSEMOVE: UINT = 0x0200, WM_LBUTTONDOWN: UINT = 0x0201, WM_LBUTTONUP: UINT = 0x0202
    static let WM_LBUTTONDBLCLK: UINT = 0x0203, WM_RBUTTONDOWN: UINT = 0x0204, WM_RBUTTONUP: UINT = 0x0205
    static let WM_MBUTTONDOWN: UINT = 0x0207, WM_MBUTTONUP: UINT = 0x0208, WM_MOUSEWHEEL: UINT = 0x020A, WM_MOUSEHWHEEL: UINT = 0x020E
    static let WM_DPICHANGED: UINT = 0x02E0
    /// More output has arrived.
    static let WM_OUTPUT: UINT = 0x8001
    /// The program ended.
    static let WM_EXITED: UINT = 0x8002
    /// Work handed over from another thread.
    static let WM_RUN: UINT = 0x8003

    static let VK_BACK: Int32 = 0x08, VK_TAB: Int32 = 0x09, VK_RETURN: Int32 = 0x0D, VK_SHIFT: Int32 = 0x10
    static let VK_CONTROL: Int32 = 0x11, VK_MENU: Int32 = 0x12, VK_ESCAPE: Int32 = 0x1B, VK_SPACE: Int32 = 0x20
    static let VK_PRIOR: Int32 = 0x21, VK_NEXT: Int32 = 0x22, VK_END: Int32 = 0x23, VK_HOME: Int32 = 0x24
    static let VK_LEFT: Int32 = 0x25, VK_UP: Int32 = 0x26, VK_RIGHT: Int32 = 0x27, VK_DOWN: Int32 = 0x28
    static let VK_INSERT: Int32 = 0x2D, VK_DELETE: Int32 = 0x2E, VK_F1: Int32 = 0x70, VK_F4: Int32 = 0x73, VK_F12: Int32 = 0x7B

    static let WS_OVERLAPPEDWINDOW: DWORD = 0x00CF_0000
    static let CW_USEDEFAULT: Int32 = Int32.min
    static let CS_DBLCLKS: UINT = 0x0008
    static let CF_UNICODETEXT: UINT = 13
    static let CF_DIB: UINT = 8
    static let GMEM_MOVEABLE: UINT = 0x0002
    static let SW_SHOW: Int32 = 5, SW_SHOWNOACTIVATE: Int32 = 4
    static let SWP_NOZORDER: UINT = 0x0004, SWP_NOACTIVATE: UINT = 0x0010, SWP_NOMOVE: UINT = 0x0002
    static let MB_ICONERROR: UINT = 0x10
    static let MK_LBUTTON: WPARAM = 0x0001, MK_RBUTTON: WPARAM = 0x0002, MK_MBUTTON: WPARAM = 0x0010
    static let WHEEL_DELTA: Int = 120
    static let ibeamCursor = UnsafePointer<WCHAR>(bitPattern: 32513)

    static let HTCLIENT: LRESULT = 1, HTCAPTION: LRESULT = 2, HTMINBUTTON: LRESULT = 8, HTMAXBUTTON: LRESULT = 9
    static let HTTOP: LRESULT = 12, HTCLOSE: LRESULT = 20
    static let SM_CYSIZEFRAME: Int32 = 33, SM_CXPADDEDBORDER: Int32 = 92
    static let SW_MINIMIZE: Int32 = 6, SW_MAXIMIZE: Int32 = 3, SW_RESTORE: Int32 = 9
    static let TME_LEAVE: DWORD = 0x02, TME_NONCLIENT: DWORD = 0x10
    static let arrowCursor = UnsafePointer<WCHAR>(bitPattern: 32512)
    static let resizeCursor = UnsafePointer<WCHAR>(bitPattern: 32644)
    static let handCursor = UnsafePointer<WCHAR>(bitPattern: 32649)
    /// Resource 1 in Support/Windows/Solanum.rc.
    static let appIcon = UnsafePointer<WCHAR>(bitPattern: 1)
    static let SWP_NOSIZE: UINT = 0x0001, SWP_FRAMECHANGED: UINT = 0x0020
}

func wide(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }
