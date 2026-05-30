using System.Windows;
using System.Windows.Media;

namespace ScreenMirroringViewer.Services;

public static class ViewTransformHelper
{
    /// <summary>Corner radius as a fraction of the window's shorter side (iPhone-like scaling).</summary>
    public const double CornerRadiusPercentOfShortSide = 0.15;

    public const double TitleBarHeight = 52;
    public const double TitleBarViewerGap = 10;
    public static double TitleBarChromeHeight => TitleBarHeight + TitleBarViewerGap;

    /// <summary>Width reserved for one side hardware button strip (button + margin).</summary>
    public const double SideButtonStripWidth = 30;

    public static double HorizontalChromeWidth => SideButtonStripWidth * 2;

    public static bool ShouldAutoRotate(int frameWidth, int frameHeight) => frameWidth > frameHeight;

    public static double CornerRadiusForSize(double width, double height)
    {
        if (width <= 0 || height <= 0)
        {
            return 28;
        }

        return Math.Min(width, height) * CornerRadiusPercentOfShortSide;
    }

    public static double AspectRatioForFrame(int frameWidth, int frameHeight, double rotationDegrees)
    {
        var display = DisplaySizeForFrame(frameWidth, frameHeight, rotationDegrees);
        return display.Width / Math.Max(1.0, display.Height);
    }

    public static Point MapDisplayToFrame(
        Point viewboxPoint,
        Size viewboxSize,
        Size contentSize,
        int frameWidth,
        int frameHeight,
        double rotationDegrees,
        bool fillViewport = false)
    {
        if (frameWidth <= 0 || frameHeight <= 0 || viewboxSize.Width <= 0 || viewboxSize.Height <= 0)
        {
            return new Point(0, 0);
        }

        var scaleX = viewboxSize.Width / contentSize.Width;
        var scaleY = viewboxSize.Height / contentSize.Height;
        var scale = fillViewport ? Math.Max(scaleX, scaleY) : Math.Min(scaleX, scaleY);
        var renderedWidth = contentSize.Width * scale;
        var renderedHeight = contentSize.Height * scale;
        var offsetX = (viewboxSize.Width - renderedWidth) / 2.0;
        var offsetY = (viewboxSize.Height - renderedHeight) / 2.0;

        var local = new Point(
            (viewboxPoint.X - offsetX) / scale,
            (viewboxPoint.Y - offsetY) / scale);

        if (local.X < 0 || local.Y < 0 || local.X > contentSize.Width || local.Y > contentSize.Height)
        {
            local.X = Math.Clamp(local.X, 0, contentSize.Width);
            local.Y = Math.Clamp(local.Y, 0, contentSize.Height);
        }

        if (Math.Abs(rotationDegrees) < 0.01)
        {
            return new Point(
                local.X / contentSize.Width * frameWidth,
                local.Y / contentSize.Height * frameHeight);
        }

        if (Math.Abs(rotationDegrees + 90) < 0.01)
        {
            return new Point(
                local.Y / contentSize.Height * frameWidth,
                (1.0 - local.X / contentSize.Width) * frameHeight);
        }

        if (Math.Abs(rotationDegrees - 90) < 0.01)
        {
            return new Point(
                (1.0 - local.Y / contentSize.Height) * frameWidth,
                local.X / contentSize.Width * frameHeight);
        }

        return new Point(
            local.X / contentSize.Width * frameWidth,
            local.Y / contentSize.Height * frameHeight);
    }

    public static Size DisplaySizeForFrame(int frameWidth, int frameHeight, double rotationDegrees)
    {
        if (Math.Abs(rotationDegrees) is > 0.01 and < 179.99)
        {
            return new Size(frameHeight, frameWidth);
        }

        return new Size(frameWidth, frameHeight);
    }
}
