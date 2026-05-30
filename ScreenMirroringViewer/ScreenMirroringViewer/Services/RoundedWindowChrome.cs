using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace ScreenMirroringViewer.Services;

internal static class RoundedWindowChrome
{
    public static void ApplyRoundedClip(FrameworkElement element, double radius)
    {
        var width = element.ActualWidth;
        var height = element.ActualHeight;
        if (width < 1 || height < 1)
        {
            return;
        }

        element.Clip = CreateRoundRectGeometry(width, height, radius);
    }

    public static RectangleGeometry CreateRoundRectGeometry(double width, double height, double radius)
    {
        radius = Math.Min(radius, Math.Min(width, height) / 2.0);
        return new RectangleGeometry(new Rect(0, 0, width, height), radius, radius);
    }

    public static void ApplyWindowRegion(Window window, double radius)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero || window.ActualWidth < 1 || window.ActualHeight < 1)
        {
            return;
        }

        var dpi = VisualTreeHelper.GetDpi(window);
        var pixelWidth = (int)Math.Ceiling(window.ActualWidth * dpi.DpiScaleX);
        var pixelHeight = (int)Math.Ceiling(window.ActualHeight * dpi.DpiScaleY);
        var pixelRadius = (int)Math.Ceiling(
            Math.Min(radius * Math.Min(dpi.DpiScaleX, dpi.DpiScaleY), Math.Min(pixelWidth, pixelHeight) / 2.0));
        var ellipse = Math.Max(2, pixelRadius * 2);

        var region = CreateRoundRectRgn(0, 0, pixelWidth + 1, pixelHeight + 1, ellipse, ellipse);
        if (region == IntPtr.Zero)
        {
            return;
        }

        SetWindowRgn(hwnd, region, true);
    }

    public static void ClearWindowRegion(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero)
        {
            return;
        }

        SetWindowRgn(hwnd, IntPtr.Zero, true);
    }

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);
}
