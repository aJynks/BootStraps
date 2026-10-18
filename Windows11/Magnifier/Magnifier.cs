// ============================================================================
//  Magnifier.cs  -  borderless, always-on-top, click-through screen magnifier
// ----------------------------------------------------------------------------
//  Build : run build.bat (uses the .NET Framework csc.exe that ships with
//          Windows; C# 5 syntax only, x64, no dependencies)
//
//  Use   : Inside the glass ........ clicks pass straight through
//          Border  left-drag ....... resize (edges + corners)
//          Border  right-drag ...... move
//          Border  mouse wheel ..... zoom in / out
//          Border  double left ..... save window layout (pos/size/zoom)
//          Border  double right .... minimise to tray
//          Tray    left-click ...... show / hide
//          Tray    right-click ..... settings + Exit
//
//  Settings are stored in Magnifier.ini next to the exe. Menu toggles save
//  immediately; the window layout (position, size, zoom) is only saved when
//  you double-left-click the border (or use "Save window layout").
// ============================================================================

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace LensMagnifier
{
    // ------------------------------------------------------------------------
    //  Win32 / Magnification API interop
    // ------------------------------------------------------------------------
    static class Native
    {
        public const int WS_CHILD   = 0x40000000;
        public const int WS_VISIBLE = 0x10000000;

        public const int WS_EX_TOPMOST     = 0x00000008;
        public const int WS_EX_TRANSPARENT = 0x00000020;
        public const int WS_EX_TOOLWINDOW  = 0x00000080;
        public const int WS_EX_LAYERED     = 0x00080000;
        public const int WS_EX_NOACTIVATE  = 0x08000000;

        public const int LWA_ALPHA = 0x2;
        public const int ULW_ALPHA = 0x2;

        public const uint SWP_NOSIZE     = 0x0001;
        public const uint SWP_NOMOVE     = 0x0002;
        public const uint SWP_NOZORDER   = 0x0004;
        public const uint SWP_NOACTIVATE = 0x0010;

        public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

        public const int WM_MOUSEACTIVATE = 0x0021;
        public const int WM_NCHITTEST     = 0x0084;
        public const int WM_DPICHANGED    = 0x02E0;
        public const int MA_NOACTIVATE    = 3;
        public const int HTTRANSPARENT    = -1;

        public const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
        public const int  MW_FILTERMODE_EXCLUDE  = 0;

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left, Top, Right, Bottom;
            public RECT(int l, int t, int r, int b) { Left = l; Top = t; Right = r; Bottom = b; }
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X, Y; }

        [StructLayout(LayoutKind.Sequential)]
        public struct SIZE { public int cx, cy; }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct BLENDFUNCTION
        {
            public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MAGTRANSFORM
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 9)]
            public float[] v;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MAGCOLOREFFECT
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 25)]
            public float[] m;
        }

        // --- user32 ---
        [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint crKey, byte bAlpha, int dwFlags);
        [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, uint crKey, ref BLENDFUNCTION pblend, int dwFlags);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hwnd, int x, int y, int w, int h, bool repaint);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool InvalidateRect(IntPtr hwnd, IntPtr rect, bool erase);
        [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hwnd, uint affinity);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateWindowEx(int exStyle, string className, string windowName, int style,
                                                   int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr hInst, IntPtr param);

        // --- shcore / kernel32 / gdi32 ---
        [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string name);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);

        // --- Magnification.dll ---
        [DllImport("Magnification.dll")] public static extern bool MagInitialize();
        [DllImport("Magnification.dll")] public static extern bool MagUninitialize();
        [DllImport("Magnification.dll")] public static extern bool MagSetWindowSource(IntPtr hwnd, RECT rect);
        [DllImport("Magnification.dll")] public static extern bool MagSetWindowTransform(IntPtr hwnd, ref MAGTRANSFORM t);
        [DllImport("Magnification.dll")] public static extern bool MagSetColorEffect(IntPtr hwnd, ref MAGCOLOREFFECT e);
        [DllImport("Magnification.dll")] public static extern bool MagSetWindowFilterList(IntPtr hwnd, int mode, int count, IntPtr[] list);

        public static void SetDpiAwareness()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch (Exception) { }   // Per-monitor v2
            try { if (SetProcessDpiAwareness(2) == 0) return; } catch (Exception) { }                  // Per-monitor
            try { SetProcessDPIAware(); } catch (Exception) { }                                         // System
        }

        public static float ScaleFor(IntPtr hwnd)
        {
            try
            {
                uint dpi = GetDpiForWindow(hwnd);
                if (dpi > 0) return dpi / 96f;
            }
            catch (Exception) { }
            return 1f;
        }

        public static Rectangle WindowRect(IntPtr hwnd)
        {
            RECT r;
            GetWindowRect(hwnd, out r);
            return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
        }

        public static void TryExcludeFromCapture(IntPtr hwnd)
        {
            try { SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE); } catch (Exception) { }
        }
    }

    // ------------------------------------------------------------------------
    //  Settings (Magnifier.ini next to the exe)
    // ------------------------------------------------------------------------
    class Settings
    {
        public int    X = int.MinValue, Y = int.MinValue, W = 480, H = 300;
        public float  Zoom        = 2f;
        public bool   Crosshair   = false;
        public bool   Invert      = false;
        public bool   BorderShow  = true;
        public string BorderColor = "Red";
        public bool   Visible     = true;

        static readonly CultureInfo CI = CultureInfo.InvariantCulture;

        static string IniPath
        {
            get { return Path.Combine(Application.StartupPath, "Magnifier.ini"); }
        }

        public static Settings Load()
        {
            Settings s = new Settings();
            try
            {
                if (!File.Exists(IniPath)) return s;
                foreach (string raw in File.ReadAllLines(IniPath))
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith(";") || line.StartsWith("#")) continue;
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    string k = line.Substring(0, eq).Trim().ToLowerInvariant();
                    string v = line.Substring(eq + 1).Trim();
                    int i; float f;
                    switch (k)
                    {
                        case "x":           if (int.TryParse(v, NumberStyles.Integer, CI, out i)) s.X = i; break;
                        case "y":           if (int.TryParse(v, NumberStyles.Integer, CI, out i)) s.Y = i; break;
                        case "width":       if (int.TryParse(v, NumberStyles.Integer, CI, out i)) s.W = i; break;
                        case "height":      if (int.TryParse(v, NumberStyles.Integer, CI, out i)) s.H = i; break;
                        case "zoom":        if (float.TryParse(v, NumberStyles.Float, CI, out f) && f >= 1f && f <= 32f) s.Zoom = f; break;
                        case "crosshair":   s.Crosshair  = ParseBool(v, s.Crosshair);  break;
                        case "invert":      s.Invert     = ParseBool(v, s.Invert);     break;
                        case "bordershow":  s.BorderShow = ParseBool(v, s.BorderShow); break;
                        case "bordercolor": s.BorderColor = v; break;
                        case "visible":     s.Visible    = ParseBool(v, s.Visible);    break;
                    }
                }
            }
            catch (Exception) { }
            return s;
        }

        public void Save()
        {
            try
            {
                List<string> l = new List<string>();
                l.Add("; Magnifier settings");
                l.Add("X=" + X.ToString(CI));
                l.Add("Y=" + Y.ToString(CI));
                l.Add("Width=" + W.ToString(CI));
                l.Add("Height=" + H.ToString(CI));
                l.Add("Zoom=" + Zoom.ToString("0.###", CI));
                l.Add("Crosshair=" + (Crosshair ? "1" : "0"));
                l.Add("Invert=" + (Invert ? "1" : "0"));
                l.Add("BorderShow=" + (BorderShow ? "1" : "0"));
                l.Add("BorderColor=" + BorderColor);
                l.Add("Visible=" + (Visible ? "1" : "0"));
                File.WriteAllLines(IniPath, l.ToArray());
            }
            catch (Exception) { }   // read-only folder etc. - just don't persist
        }

        static bool ParseBool(string v, bool def)
        {
            v = v.ToLowerInvariant();
            if (v == "1" || v == "true" || v == "yes" || v == "on") return true;
            if (v == "0" || v == "false" || v == "no" || v == "off") return false;
            return def;
        }
    }

    // ------------------------------------------------------------------------
    //  Lens window: hosts the Magnifier control, fully click-through
    // ------------------------------------------------------------------------
    class LensForm : Form
    {
        IntPtr hwndMag = IntPtr.Zero;
        float  zoom    = 2f;
        bool   invert  = false;

        public LensForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar   = false;
            StartPosition   = FormStartPosition.Manual;
            AutoScaleMode   = AutoScaleMode.None;
            BackColor       = Color.Black;
            TopMost         = true;
            Text            = "Magnifier Lens";
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TRANSPARENT | Native.WS_EX_TOOLWINDOW
                            | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST;
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.SetLayeredWindowAttributes(Handle, 0, 255, Native.LWA_ALPHA);
            hwndMag = Native.CreateWindowEx(0, "Magnifier", "MagnifierWindow", Native.WS_CHILD | Native.WS_VISIBLE,
                                            0, 0, Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height),
                                            Handle, IntPtr.Zero, Native.GetModuleHandle(null), IntPtr.Zero);
            ApplyTransform();
            ApplyColor();
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_MOUSEACTIVATE) { m.Result = (IntPtr)Native.MA_NOACTIVATE; return; }
            if (m.Msg == Native.WM_NCHITTEST)     { m.Result = (IntPtr)Native.HTTRANSPARENT; return; }
            if (m.Msg == Native.WM_DPICHANGED)    { m.Result = IntPtr.Zero; return; }   // we size in physical px ourselves
            base.WndProc(ref m);
        }

        public bool Ready { get { return hwndMag != IntPtr.Zero; } }

        public void SyncMagSize(int w, int h)
        {
            if (hwndMag != IntPtr.Zero) Native.MoveWindow(hwndMag, 0, 0, w, h, true);
        }

        public void SetZoom(float z) { zoom = z; ApplyTransform(); UpdateSource(); }
        public void SetInvert(bool on) { invert = on; ApplyColor(); }

        public void SetFilter(IntPtr[] exclude)
        {
            if (hwndMag != IntPtr.Zero)
                Native.MagSetWindowFilterList(hwndMag, Native.MW_FILTERMODE_EXCLUDE, exclude.Length, exclude);
        }

        void ApplyTransform()
        {
            if (hwndMag == IntPtr.Zero) return;
            Native.MAGTRANSFORM t;
            t.v = new float[] { zoom, 0f, 0f,
                                0f, zoom, 0f,
                                0f, 0f, 1f };
            Native.MagSetWindowTransform(hwndMag, ref t);
        }

        void ApplyColor()
        {
            if (hwndMag == IntPtr.Zero) return;
            Native.MAGCOLOREFFECT c;
            if (invert)
                c.m = new float[] { -1f,  0f,  0f, 0f, 0f,
                                     0f, -1f,  0f, 0f, 0f,
                                     0f,  0f, -1f, 0f, 0f,
                                     0f,  0f,  0f, 1f, 0f,
                                     1f,  1f,  1f, 0f, 1f };
            else
                c.m = new float[] { 1f, 0f, 0f, 0f, 0f,
                                    0f, 1f, 0f, 0f, 0f,
                                    0f, 0f, 1f, 0f, 0f,
                                    0f, 0f, 0f, 1f, 0f,
                                    0f, 0f, 0f, 0f, 1f };
            Native.MagSetColorEffect(hwndMag, ref c);
        }

        // Called every tick: source = the lens rect shrunk by the zoom, around its centre.
        public void UpdateSource()
        {
            if (hwndMag == IntPtr.Zero) return;
            Rectangle r = Native.WindowRect(Handle);
            int sw = Math.Max(1, (int)Math.Round(r.Width  / zoom));
            int sh = Math.Max(1, (int)Math.Round(r.Height / zoom));
            int cx = r.Left + r.Width  / 2;
            int cy = r.Top  + r.Height / 2;
            int left = cx - sw / 2;
            int top  = cy - sh / 2;
            Native.MagSetWindowSource(hwndMag, new Native.RECT(left, top, left + sw, top + sh));
            Native.InvalidateRect(hwndMag, IntPtr.Zero, true);
        }
    }

    // ------------------------------------------------------------------------
    //  Base for per-pixel-alpha overlay windows (frame + crosshair)
    //  Pixels with alpha 0 are click-through; anything else is hittable.
    // ------------------------------------------------------------------------
    abstract class LayeredForm : Form
    {
        protected LayeredForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar   = false;
            StartPosition   = FormStartPosition.Manual;
            AutoScaleMode   = AutoScaleMode.None;
            TopMost         = true;
        }

        protected abstract bool ClickThrough { get; }
        protected virtual void OnNativeDpiChanged() { }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_LAYERED | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST;
                if (ClickThrough) cp.ExStyle |= Native.WS_EX_TRANSPARENT;
                return cp;
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_MOUSEACTIVATE) { m.Result = (IntPtr)Native.MA_NOACTIVATE; return; }
            if (m.Msg == Native.WM_DPICHANGED)    { m.Result = IntPtr.Zero; OnNativeDpiChanged(); return; }
            base.WndProc(ref m);
        }

        // Pushes a 32bpp ARGB bitmap to the window, moving/resizing it to pos/bitmap size.
        protected void PushBitmap(Bitmap bmp, Point pos)
        {
            IntPtr screenDc = Native.GetDC(IntPtr.Zero);
            IntPtr memDc    = Native.CreateCompatibleDC(screenDc);
            IntPtr hBmp     = IntPtr.Zero;
            IntPtr oldBmp   = IntPtr.Zero;
            try
            {
                hBmp   = bmp.GetHbitmap(Color.FromArgb(0));
                oldBmp = Native.SelectObject(memDc, hBmp);

                Native.SIZE  size; size.cx = bmp.Width; size.cy = bmp.Height;
                Native.POINT src;  src.X = 0; src.Y = 0;
                Native.POINT dst;  dst.X = pos.X; dst.Y = pos.Y;
                Native.BLENDFUNCTION bf;
                bf.BlendOp = 0; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = 1; // AC_SRC_ALPHA

                Native.UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref bf, Native.ULW_ALPHA);
            }
            finally
            {
                if (hBmp != IntPtr.Zero)
                {
                    Native.SelectObject(memDc, oldBmp);
                    Native.DeleteObject(hBmp);
                }
                Native.DeleteDC(memDc);
                Native.ReleaseDC(IntPtr.Zero, screenDc);
            }
        }

        protected static void Fill(Graphics g, Brush b, int x, int y, int w, int h)
        {
            if (w > 0 && h > 0) g.FillRectangle(b, x, y, w, h);
        }
    }

    // ------------------------------------------------------------------------
    //  Frame: hollow ring over the lens edge. Left-drag resize, right-drag move,
    //  wheel zoom. Interior pixels are alpha 0 so clicks fall through.
    // ------------------------------------------------------------------------
    class FrameForm : LayeredForm
    {
        public Action<Rectangle, bool> RectRequested;   // (newRect, sizeChanged)
        public Action DragFinished;
        public Action DoubleLeft;
        public Action DoubleRight;
        public Action<int> WheelZoom;
        public Action DpiChangedAction;

        bool  showLine  = true;
        Color lineColor = Color.Red;
        Color flashColor = Color.Empty;
        System.Windows.Forms.Timer flashTimer;

        int       dragMode = 0;      // 0 none, 1 resize, 2 move
        bool      dragActive;        // passed the drag threshold
        bool      zl, zr, zt, zb;    // active zone
        Point     startMouse;
        Rectangle startRect;

        public FrameForm()
        {
            Text = "Magnifier Frame";
            flashTimer = new System.Windows.Forms.Timer();
            flashTimer.Interval = 350;
            flashTimer.Tick += delegate
            {
                flashTimer.Stop();
                flashColor = Color.Empty;
                Render(Native.WindowRect(Handle));
            };
        }

        // Briefly draws a thick coloured border as feedback
        public void Flash(Color c)
        {
            flashColor = c;
            Render(Native.WindowRect(Handle));
            flashTimer.Stop();
            flashTimer.Start();
        }

        protected override bool ClickThrough { get { return false; } }

        protected override void OnNativeDpiChanged()
        {
            if (DpiChangedAction != null) DpiChangedAction();
        }

        float Scale_ { get { return Native.ScaleFor(Handle); } }
        public int GrabPx   { get { return Math.Max(6, (int)Math.Round(6 * Scale_)); } }
        public int CornerPx { get { return GrabPx * 3; } }
        public int MinSize  { get { return Math.Max(80, (int)Math.Round(80 * Scale_)); } }

        public void SetLine(bool show, Color c) { showLine = show; lineColor = c; }

        public void Render(Rectangle r)
        {
            if (r.Width <= 0 || r.Height <= 0) return;
            int g  = GrabPx;
            int lw = Math.Max(1, (int)Math.Round(Scale_));
            int w  = r.Width, h = r.Height;

            using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (Graphics gr = Graphics.FromImage(bmp))
                {
                    gr.CompositingMode = CompositingMode.SourceCopy;
                    gr.Clear(Color.Transparent);

                    // Invisible-but-hittable grab ring (alpha 1)
                    using (SolidBrush grab = new SolidBrush(Color.FromArgb(1, 0, 0, 0)))
                    {
                        Fill(gr, grab, 0, 0, w, g);
                        Fill(gr, grab, 0, h - g, w, g);
                        Fill(gr, grab, 0, g, g, h - 2 * g);
                        Fill(gr, grab, w - g, g, g, h - 2 * g);
                    }

                    // Visible edge line (or thick flash line)
                    bool flashing = flashColor != Color.Empty;
                    if (flashing) lw = g;
                    if (showLine || flashing)
                    {
                        Color lc = flashing ? flashColor : lineColor;
                        using (SolidBrush line = new SolidBrush(Color.FromArgb(255, lc.R, lc.G, lc.B)))
                        {
                            Fill(gr, line, 0, 0, w, lw);
                            Fill(gr, line, 0, h - lw, w, lw);
                            Fill(gr, line, 0, 0, lw, h);
                            Fill(gr, line, w - lw, 0, lw, h);
                        }
                    }
                }
                PushBitmap(bmp, r.Location);
            }
        }

        void SetZone(int x, int y)
        {
            Rectangle r = Native.WindowRect(Handle);
            int w = r.Width, h = r.Height, g = GrabPx, c = CornerPx;
            zl = x < g; zr = x >= w - g; zt = y < g; zb = y >= h - g;
            if (zl || zr) { if (y < c) zt = true; else if (y >= h - c) zb = true; }
            if (zt || zb) { if (x < c) zl = true; else if (x >= w - c) zr = true; }
        }

        Cursor ZoneCursor()
        {
            if ((zl && zt) || (zr && zb)) return Cursors.SizeNWSE;
            if ((zr && zt) || (zl && zb)) return Cursors.SizeNESW;
            if (zl || zr) return Cursors.SizeWE;
            if (zt || zb) return Cursors.SizeNS;
            return Cursors.Default;
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);

            // Second press of a double-click: action instead of a drag
            if (e.Clicks >= 2)
            {
                dragMode = 0;
                dragActive = false;
                if (e.Button == MouseButtons.Left  && DoubleLeft  != null) DoubleLeft();
                if (e.Button == MouseButtons.Right && DoubleRight != null) DoubleRight();
                return;
            }

            if (dragMode != 0) return;
            dragActive = false;
            SetZone(e.X, e.Y);
            startMouse = Cursor.Position;
            startRect  = Native.WindowRect(Handle);
            if (e.Button == MouseButtons.Left)
            {
                if (!(zl || zr || zt || zb)) return;
                dragMode = 1;
            }
            else if (e.Button == MouseButtons.Right)
            {
                dragMode = 2;
                Cursor = Cursors.SizeAll;
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (dragMode == 0)
            {
                SetZone(e.X, e.Y);
                Cursor = ZoneCursor();
                return;
            }

            Point p = Cursor.Position;
            int dx = p.X - startMouse.X;
            int dy = p.Y - startMouse.Y;

            // Ignore tiny jitter so clicks/double-clicks don't nudge the window
            if (!dragActive)
            {
                Size ds = SystemInformation.DragSize;
                if (Math.Abs(dx) <= ds.Width / 2 && Math.Abs(dy) <= ds.Height / 2) return;
                dragActive = true;
            }

            if (dragMode == 2)
            {
                Rectangle r = startRect;
                r.Offset(dx, dy);
                if (RectRequested != null) RectRequested(r, false);
                return;
            }

            int L = startRect.Left, T = startRect.Top, R = startRect.Right, B = startRect.Bottom;
            if (zl) L += dx;
            if (zr) R += dx;
            if (zt) T += dy;
            if (zb) B += dy;
            int min = MinSize;
            if (R - L < min) { if (zl) L = R - min; else R = L + min; }
            if (B - T < min) { if (zt) T = B - min; else B = T + min; }
            if (RectRequested != null) RectRequested(Rectangle.FromLTRB(L, T, R, B), true);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            EndDrag();
        }

        protected override void OnMouseCaptureChanged(EventArgs e)
        {
            base.OnMouseCaptureChanged(e);
            EndDrag();
        }

        void EndDrag()
        {
            if (dragMode == 0) return;
            bool moved = dragActive;
            dragMode = 0;
            dragActive = false;
            Cursor = ZoneCursor();
            if (moved && DragFinished != null) DragFinished();
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            if (WheelZoom != null && e.Delta != 0) WheelZoom(e.Delta);
        }
    }

    // ------------------------------------------------------------------------
    //  Crosshair: small click-through reticle at the lens centre
    // ------------------------------------------------------------------------
    class CrossForm : LayeredForm
    {
        public CrossForm() { Text = "Magnifier Crosshair"; }

        protected override bool ClickThrough { get { return true; } }

        public void RenderAt(int cx, int cy)
        {
            float s  = Native.ScaleFor(Handle);
            int t    = Math.Max(1, (int)Math.Round(s));        // line thickness
            int o    = Math.Max(1, (int)Math.Round(s));        // outline
            int arm  = Math.Max(6, (int)Math.Round(8 * s));
            int gap  = Math.Max(2, (int)Math.Round(3 * s));
            int half = gap + arm + o;
            int size = half * 2 + t;

            using (Bitmap bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.CompositingMode = CompositingMode.SourceCopy;
                    g.Clear(Color.Transparent);
                    using (SolidBrush black = new SolidBrush(Color.FromArgb(255, 0, 0, 0)))
                    {
                        Fill(g, black, half - gap - arm - o, half - o, arm + 2 * o, t + 2 * o);
                        Fill(g, black, half + t + gap - o,  half - o, arm + 2 * o, t + 2 * o);
                        Fill(g, black, half - o, half - gap - arm - o, t + 2 * o, arm + 2 * o);
                        Fill(g, black, half - o, half + t + gap - o,  t + 2 * o, arm + 2 * o);
                    }
                    using (SolidBrush white = new SolidBrush(Color.FromArgb(255, 255, 255, 255)))
                    {
                        Fill(g, white, half - gap - arm, half, arm, t);
                        Fill(g, white, half + t + gap,  half, arm, t);
                        Fill(g, white, half, half - gap - arm, t, arm);
                        Fill(g, white, half, half + t + gap,  t, arm);
                    }
                }
                PushBitmap(bmp, new Point(cx - half, cy - half));
            }
        }
    }

    // ------------------------------------------------------------------------
    //  Application: owns the windows, tray icon, timer and settings
    // ------------------------------------------------------------------------
    class MagnifierApp : ApplicationContext
    {
        static readonly float[] Zooms = { 1.5f, 2f, 3f, 4f, 6f, 8f };

        static readonly string[] ColorNames = { "Red", "White", "Black", "Cyan", "Yellow", "Lime", "Magenta", "Gray" };
        static readonly Color[]  ColorVals  = { Color.FromArgb(255, 40, 40), Color.White, Color.Black, Color.Cyan,
                                                Color.Yellow, Color.Lime, Color.Magenta, Color.Gray };

        const string RunKey  = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "LensMagnifier";

        Settings   cfg;
        LensForm   lens;
        FrameForm  frame;
        CrossForm  cross;
        NotifyIcon tray;
        System.Windows.Forms.Timer timer;

        Rectangle rect;
        float zoom;
        bool shown;
        bool menuOpen;
        int  topTick;

        MenuItem miShow, miCross, miInvert, miBorderShow, miStartup;
        List<MenuItem> zoomItems  = new List<MenuItem>();
        List<MenuItem> colorItems = new List<MenuItem>();

        public MagnifierApp()
        {
            cfg   = Settings.Load();
            lens  = new LensForm();
            frame = new FrameForm();
            cross = new CrossForm();

            // Force handle creation (without showing)
            IntPtr hl = lens.Handle, hf = frame.Handle, hc = cross.Handle;

            if (!lens.Ready)
            {
                MessageBox.Show("Could not create the Magnifier control.", "Magnifier",
                                MessageBoxButtons.OK, MessageBoxIcon.Error);
            }

            // Keep our own overlays out of the magnified image
            lens.SetFilter(new IntPtr[] { hl, hf, hc });
            Native.TryExcludeFromCapture(hf);
            Native.TryExcludeFromCapture(hc);

            zoom = cfg.Zoom;
            lens.SetZoom(zoom);
            lens.SetInvert(cfg.Invert);
            frame.SetLine(cfg.BorderShow, LookupColor(cfg.BorderColor));

            frame.RectRequested    = delegate(Rectangle r, bool sized) { ApplyRect(r, sized); };
            frame.DoubleLeft       = delegate { SaveLayout(); };
            frame.DoubleRight      = delegate { SetShown(false); };
            frame.WheelZoom        = delegate(int d) { StepZoom(d > 0 ? 1 : -1); };
            frame.DpiChangedAction = delegate { ApplyRect(rect, true); };

            rect = ValidRect(new Rectangle(cfg.X, cfg.Y, cfg.W, cfg.H));

            timer = new System.Windows.Forms.Timer();
            timer.Interval = 15;
            timer.Tick += OnTick;

            tray = new NotifyIcon();
            tray.Icon = MakeIcon();
            tray.Text = "Magnifier";
            tray.ContextMenu = BuildMenu();
            tray.MouseClick += delegate(object s, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left) SetShown(!shown);
            };
            tray.Visible = true;

            SetShown(cfg.Visible);
        }

        // --- geometry ---------------------------------------------------------

        void ApplyRect(Rectangle r, bool sized)
        {
            rect = r;
            Native.SetWindowPos(lens.Handle, IntPtr.Zero, r.X, r.Y, r.Width, r.Height,
                                Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
            lens.SyncMagSize(r.Width, r.Height);

            if (sized)
                frame.Render(r);
            else
                Native.SetWindowPos(frame.Handle, IntPtr.Zero, r.X, r.Y, 0, 0,
                                    Native.SWP_NOZORDER | Native.SWP_NOACTIVATE | Native.SWP_NOSIZE);

            if (cfg.Crosshair) cross.RenderAt(r.X + r.Width / 2, r.Y + r.Height / 2);
            lens.UpdateSource();
        }

        // Stores the current position, size and zoom as the startup layout
        void SaveLayout()
        {
            cfg.X = rect.X; cfg.Y = rect.Y; cfg.W = rect.Width; cfg.H = rect.Height;
            cfg.Zoom = zoom;
            cfg.Save();
            if (shown) frame.Flash(Color.Lime);
        }

        static Rectangle DefaultRect()
        {
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            int w = 480, h = 300;
            return new Rectangle(wa.X + (wa.Width - w) / 2, wa.Y + (wa.Height - h) / 2, w, h);
        }

        static Rectangle ValidRect(Rectangle r)
        {
            if (r.X == int.MinValue || r.Y == int.MinValue || r.Width < 40 || r.Height < 40) return DefaultRect();
            foreach (Screen s in Screen.AllScreens)
            {
                Rectangle i = Rectangle.Intersect(s.WorkingArea, r);
                if (i.Width >= 40 && i.Height >= 40) return r;
            }
            return DefaultRect();
        }

        // --- visibility / z-order -------------------------------------------

        void SetShown(bool v)
        {
            shown = v;
            cfg.Visible = v;
            if (v)
            {
                ApplyRect(rect, true);
                lens.Show();
                if (cfg.Crosshair) cross.Show();
                frame.Show();
                ApplyRect(rect, true);
                ReassertTopmost();
                timer.Start();
            }
            else
            {
                timer.Stop();
                frame.Hide();
                cross.Hide();
                lens.Hide();
            }
            cfg.Save();
        }

        void ReassertTopmost()
        {
            uint f = Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE;
            Native.SetWindowPos(lens.Handle, Native.HWND_TOPMOST, 0, 0, 0, 0, f);
            if (cfg.Crosshair) Native.SetWindowPos(cross.Handle, Native.HWND_TOPMOST, 0, 0, 0, 0, f);
            Native.SetWindowPos(frame.Handle, Native.HWND_TOPMOST, 0, 0, 0, 0, f);
        }

        void OnTick(object sender, EventArgs e)
        {
            lens.UpdateSource();
            if (++topTick >= 66)   // ~once a second
            {
                topTick = 0;
                if (!menuOpen) ReassertTopmost();
            }
        }

        // --- settings actions ------------------------------------------------

        void SetZoom(float z)
        {
            zoom = z;
            lens.SetZoom(z);
        }

        void StepZoom(int dir)
        {
            int idx = 0;
            float best = float.MaxValue;
            for (int i = 0; i < Zooms.Length; i++)
            {
                float d = Math.Abs(Zooms[i] - zoom);
                if (d < best) { best = d; idx = i; }
            }
            idx = Math.Max(0, Math.Min(Zooms.Length - 1, idx + dir));
            SetZoom(Zooms[idx]);
        }

        void SetCrosshair(bool on)
        {
            cfg.Crosshair = on;
            if (on && shown)
            {
                cross.RenderAt(rect.X + rect.Width / 2, rect.Y + rect.Height / 2);
                cross.Show();
                ReassertTopmost();
            }
            else cross.Hide();
            cfg.Save();
        }

        void SetInvert(bool on)
        {
            cfg.Invert = on;
            lens.SetInvert(on);
            cfg.Save();
        }

        void SetBorder(bool show, string colorName)
        {
            cfg.BorderShow  = show;
            cfg.BorderColor = colorName;
            frame.SetLine(show, LookupColor(colorName));
            if (shown) frame.Render(rect);
            cfg.Save();
        }

        static Color LookupColor(string name)
        {
            for (int i = 0; i < ColorNames.Length; i++)
                if (string.Equals(ColorNames[i], name, StringComparison.OrdinalIgnoreCase)) return ColorVals[i];
            return ColorVals[0];
        }

        static bool IsStartup()
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey, false))
                    return k != null && k.GetValue(RunName) != null;
            }
            catch (Exception) { return false; }
        }

        static void SetStartup(bool on)
        {
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (on) k.SetValue(RunName, "\"" + Application.ExecutablePath + "\"");
                    else    k.DeleteValue(RunName, false);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Could not update startup setting:\n" + ex.Message, "Magnifier",
                                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        void ResetPosition()
        {
            ApplyRect(DefaultRect(), true);
        }

        void ExitApp()
        {
            timer.Stop();
            tray.Visible = false;
            tray.Dispose();
            frame.Close(); cross.Close(); lens.Close();
            ExitThread();
        }

        // --- tray menu -------------------------------------------------------

        ContextMenu BuildMenu()
        {
            ContextMenu m = new ContextMenu();

            miShow = new MenuItem("Show magnifier", delegate { SetShown(!shown); });
            m.MenuItems.Add(miShow);
            m.MenuItems.Add("-");

            MenuItem zoomMenu = new MenuItem("Zoom");
            foreach (float z in Zooms)
            {
                float zz = z;
                MenuItem mi = new MenuItem(zz.ToString("0.#", CultureInfo.InvariantCulture) + "\u00D7",
                                           delegate { SetZoom(zz); });
                mi.RadioCheck = true;
                mi.Tag = zz;
                zoomMenu.MenuItems.Add(mi);
                zoomItems.Add(mi);
            }
            m.MenuItems.Add(zoomMenu);

            miCross  = new MenuItem("Centre crosshair", delegate { SetCrosshair(!cfg.Crosshair); });
            miInvert = new MenuItem("Invert colours",   delegate { SetInvert(!cfg.Invert); });
            m.MenuItems.Add(miCross);
            m.MenuItems.Add(miInvert);

            MenuItem borderMenu = new MenuItem("Border line");
            miBorderShow = new MenuItem("Show line", delegate { SetBorder(!cfg.BorderShow, cfg.BorderColor); });
            borderMenu.MenuItems.Add(miBorderShow);
            borderMenu.MenuItems.Add("-");
            foreach (string name in ColorNames)
            {
                string nn = name;
                MenuItem mi = new MenuItem(nn, delegate { SetBorder(cfg.BorderShow, nn); });
                mi.RadioCheck = true;
                mi.Tag = nn;
                borderMenu.MenuItems.Add(mi);
                colorItems.Add(mi);
            }
            m.MenuItems.Add(borderMenu);

            m.MenuItems.Add("-");
            miStartup = new MenuItem("Start with Windows", delegate { SetStartup(!IsStartup()); });
            m.MenuItems.Add(miStartup);
            m.MenuItems.Add(new MenuItem("Save window layout", delegate { SaveLayout(); }));
            m.MenuItems.Add(new MenuItem("Reset position", delegate { ResetPosition(); }));
            m.MenuItems.Add("-");
            m.MenuItems.Add(new MenuItem("Exit", delegate { ExitApp(); }));

            m.Popup    += delegate { menuOpen = true; RefreshChecks(); };
            m.Collapse += delegate { menuOpen = false; };
            return m;
        }

        void RefreshChecks()
        {
            miShow.Checked       = shown;
            miCross.Checked      = cfg.Crosshair;
            miInvert.Checked     = cfg.Invert;
            miBorderShow.Checked = cfg.BorderShow;
            miStartup.Checked    = IsStartup();
            foreach (MenuItem mi in zoomItems)
                mi.Checked = Math.Abs((float)mi.Tag - zoom) < 0.01f;
            foreach (MenuItem mi in colorItems)
                mi.Checked = string.Equals((string)mi.Tag, cfg.BorderColor, StringComparison.OrdinalIgnoreCase);
        }

        // --- tray icon (drawn at runtime, no .ico needed) --------------------

        static Icon MakeIcon()
        {
            int sz = Math.Max(16, SystemInformation.SmallIconSize.Width);
            float s = sz / 16f;
            using (Bitmap bmp = new Bitmap(sz, sz, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    using (Pen handleOut = new Pen(Color.Black, 4.2f * s))
                    using (Pen handle    = new Pen(Color.FromArgb(255, 235, 170, 40), 2.6f * s))
                    using (Pen ringOut   = new Pen(Color.Black, 3.2f * s))
                    using (Pen ring      = new Pen(Color.White, 1.6f * s))
                    using (SolidBrush glass = new SolidBrush(Color.FromArgb(200, 110, 190, 255)))
                    {
                        handleOut.StartCap = handleOut.EndCap = LineCap.Round;
                        handle.StartCap    = handle.EndCap    = LineCap.Round;
                        g.DrawLine(handleOut, 10f * s, 10f * s, 14.3f * s, 14.3f * s);
                        g.DrawLine(handle,    10f * s, 10f * s, 14.3f * s, 14.3f * s);
                        RectangleF c = new RectangleF(1.8f * s, 1.8f * s, 9.2f * s, 9.2f * s);
                        g.FillEllipse(glass, c);
                        g.DrawEllipse(ringOut, c);
                        g.DrawEllipse(ring, c);
                    }
                }
                return Icon.FromHandle(bmp.GetHicon());
            }
        }
    }

    // ------------------------------------------------------------------------
    static class Program
    {
        [STAThread]
        static void Main()
        {
            bool created;
            using (Mutex mutex = new Mutex(true, @"Local\LensMagnifier_SingleInstance", out created))
            {
                if (!created) return;   // already running

                Native.SetDpiAwareness();
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                bool magOk = false;
                try { magOk = Native.MagInitialize(); } catch (Exception) { }
                if (!magOk)
                {
                    MessageBox.Show("Failed to initialise the Windows Magnification API.\n" +
                                    "Make sure this was built as x64 on 64-bit Windows.",
                                    "Magnifier", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }

                try { Application.Run(new MagnifierApp()); }
                finally { Native.MagUninitialize(); }
            }
        }
    }
}
