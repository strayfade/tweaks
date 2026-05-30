using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using ScreenMirroringViewer.Models;
using ScreenMirroringViewer.Services;

namespace ScreenMirroringViewer;

public partial class MainWindow : Window
{
    private const int DwmwaWindowCornerPreference = 33;
    private const int DwmwcpDoNotRound = 1;
    private const double TitleBarFadeDurationMs = 180;
    private const int AutoRetryDelayMs = 3000;

    private readonly DeviceDiscoveryService _discovery = new();
    private readonly ScreenMirroringVncClient _vncClient = new();
    private readonly AppSettings _settings;
    private readonly DispatcherTimer _frameTimer;

    private DiscoveredDevice? _selectedDevice;
    private bool _connecting;
    private bool _statusUpdatesPaused;
    private bool _manualRotationOverride;
    private bool _lastFrameWasLandscape;
    private double _viewRotation;
    private byte _activePointerButtonMask;
    private Point _lastPointer;
    private double _lockedAspectRatio = 390.0 / 844.0;
    private bool _isAdjustingSize;
    private bool _mouseOverTitleBarZone;
    private bool _mouseOverViewer;
    private DispatcherTimer? _autoRetryTimer;

    private double ViewerChromeTop =>
        TitleBarHitZone?.ActualHeight > 0
            ? TitleBarHitZone.ActualHeight
            : ViewTransformHelper.TitleBarChromeHeight;

    private double TitleHoverStripHeight =>
        TitleBarHitZone?.ActualHeight > 0
            ? TitleBarHitZone.ActualHeight
            : ViewTransformHelper.TitleBarChromeHeight;

    public MainWindow()
    {
        InitializeComponent();
        _settings = AppSettings.Load();
        _frameTimer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(16),
        };
        _frameTimer.Tick += FrameTimer_Tick;
        TitleBarChrome.Opacity = 0;
        TitleBarChrome.IsHitTestVisible = false;

        _discovery.StatusChanged += status => Dispatcher.Invoke(() => SetStatus(status));
        _discovery.DeviceFound += device => Dispatcher.Invoke(() => _ = TryAutoConnectAsync(device));
        _vncClient.ConnectionFailed += ex => Dispatcher.Invoke(() => HandleConnectionFailure(ex));
        _vncClient.Disconnected += () => Dispatcher.Invoke(HandleDisconnected);
        _vncClient.FrameDimensionsChanged += (width, height) => Dispatcher.Invoke(() => UpdateRotationForFrame(width, height));
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        DisableSystemWindowRounding();
        SourceInitialized += (_, _) => UpdateRoundedClip();
        await BeginDiscoveryAndConnectAsync();
    }

    private void MainWindow_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        EnforceLockedAspectRatio(e);
        UpdateRoundedClip();
    }

    private void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        _frameTimer.Stop();
        _autoRetryTimer?.Stop();
        _discovery.Dispose();
        _ = _vncClient.DisposeAsync();
        _settings.Save();
    }

    private async Task BeginDiscoveryAndConnectAsync()
    {
        if (_connecting || _vncClient.IsConnected)
        {
            return;
        }

        if (!await EnsureDiscoveryRunningAsync(showSearchingOverlay: true))
        {
            return;
        }

        await TryConnectToLastKnownDeviceAsync();
    }

    private async Task<bool> EnsureDiscoveryRunningAsync(bool showSearchingOverlay = false)
    {
        if (_vncClient.IsConnected || _discovery.IsBrowsing)
        {
            return _discovery.IsBrowsing;
        }

        if (showSearchingOverlay)
        {
            DeviceSubtitleText.Text = "Discovering…";
            ShowOverlay("Searching for Screen Mirroring devices…", busy: true);
        }

        var started = await Task.Run(() => _discovery.StartBrowsing());
        if (!started)
        {
            var detail = _discovery.LastError ?? "Discovery could not be started.";
            ShowOverlay($"{detail} Retrying…", busy: true);
            ScheduleAutoRetry();
            return false;
        }

        return true;
    }

    private async Task TryConnectToLastKnownDeviceAsync()
    {
        if (string.IsNullOrWhiteSpace(_settings.LastKnownHost))
        {
            return;
        }

        var device = CreateCachedDevice(_settings.LastKnownHost, _settings.LastKnownDeviceName);
        await TryAutoConnectAsync(device);
    }

    private static DiscoveredDevice CreateCachedDevice(string host, string? name) =>
        new()
        {
            Name = string.IsNullOrWhiteSpace(name) ? host : name,
            Host = host.Trim(),
            Port = ScreenMirroringProtocol.ServerPort,
            Platform = ScreenMirroringProtocol.PlatformId,
            Vendor = ScreenMirroringProtocol.VendorId,
            Source = DiscoverySource.LastKnown,
        };

    private void SaveLastKnownDevice(DiscoveredDevice device)
    {
        _settings.LastKnownHost = device.Host;
        _settings.LastKnownDeviceName = device.Name;
        _settings.Save();
    }

    private async Task TryAutoConnectAsync(DiscoveredDevice device)
    {
        if (_vncClient.IsConnected || _connecting)
        {
            return;
        }

        _statusUpdatesPaused = true;
        _connecting = true;
        _selectedDevice = device;
        DeviceTitleText.Text = device.Name;
        DeviceSubtitleText.Text = "Connecting…";

        try
        {
            var password = await ResolvePasswordAsync(device.Name);
            if (string.IsNullOrEmpty(password))
            {
                _selectedDevice = null;
                ShowOverlay("Searching for Screen Mirroring devices…", busy: true);
                DeviceSubtitleText.Text = "Discovering…";
                _ = EnsureDiscoveryRunningAsync();
                return;
            }

            await ConnectToDeviceAsync(device, password);
        }
        finally
        {
            _connecting = false;
            _statusUpdatesPaused = false;
        }
    }

    private async Task ConnectToDeviceAsync(DiscoveredDevice device, string password)
    {
        ShowOverlay($"Connecting to {device.Name}…", busy: true);
        try
        {
            await _vncClient.ConnectAsync(device.Host, ScreenMirroringProtocol.ServerPort, password);
            SaveLastKnownDevice(device);
            _discovery.StopBrowsing();
            _autoRetryTimer?.Stop();
            UpdateHardwareButtonsEnabled(true);
            DeviceSubtitleText.Text = "Connected";
            HideOverlay();
            Focus();
            Keyboard.Focus(this);
            _frameTimer.Start();
        }
        catch (Exception ex)
        {
            HandleConnectionFailure(ex);
        }
    }

    private Task<string?> ResolvePasswordAsync(string deviceName)
    {
        if (_settings.RememberPassword && !string.IsNullOrEmpty(_settings.SavedPassword))
        {
            return Task.FromResult<string?>(_settings.SavedPassword);
        }

        var dialog = new PasswordDialog(deviceName)
        {
            Owner = this,
        };

        if (dialog.ShowDialog() != true)
        {
            return Task.FromResult<string?>(null);
        }

        if (_settings.RememberPassword)
        {
            _settings.SavedPassword = dialog.Password;
        }

        return Task.FromResult<string?>(dialog.Password);
    }

    private void HandleConnectionFailure(Exception exception)
    {
        _frameTimer.Stop();
        UpdateHardwareButtonsEnabled(false);
        var failedHost = _selectedDevice?.Host;
        _selectedDevice = null;
        if (!string.IsNullOrEmpty(failedHost))
        {
            _discovery.ForgetReportedHost(failedHost);
        }

        ShowOverlay("Searching for Screen Mirroring devices…", busy: true);
        DeviceSubtitleText.Text = "Connection failed";
        _ = EnsureDiscoveryRunningAsync();
        ScheduleAutoRetry();
    }

    private void HandleDisconnected()
    {
        _frameTimer.Stop();
        FrameImage.Source = null;
        _activePointerButtonMask = 0;
        UpdateHardwareButtonsEnabled(false);
        _selectedDevice = null;
        DeviceSubtitleText.Text = "Disconnected";
        ShowOverlay("Searching for Screen Mirroring devices…", busy: true);
        _ = EnsureDiscoveryRunningAsync();
        ScheduleAutoRetry();
    }

    private void ScheduleAutoRetry()
    {
        if (_vncClient.IsConnected || _connecting)
        {
            return;
        }

        _autoRetryTimer?.Stop();
        _autoRetryTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(AutoRetryDelayMs),
        };
        _autoRetryTimer.Tick += AutoRetryTimer_Tick;
        _autoRetryTimer.Start();
    }

    private async void AutoRetryTimer_Tick(object? sender, EventArgs e)
    {
        _autoRetryTimer?.Stop();
        await AutoRetryAsync();
    }

    private async Task AutoRetryAsync()
    {
        if (_connecting || _vncClient.IsConnected)
        {
            return;
        }

        await _vncClient.DisconnectAsync();
        _selectedDevice = null;
        _discovery.ResetReportedHosts();
        await BeginDiscoveryAndConnectAsync();
    }

    private void MainWindow_MouseMove(object sender, MouseEventArgs e)
    {
        UpdateTitleBarHoverState(e);
        ReleasePointerButtonsIfOutsideViewer(e);
    }

    private void UpdateTitleBarHoverState(MouseEventArgs e)
    {
        var position = e.GetPosition(ChromeHoverRegion);
        var titleStripHeight = TitleHoverStripHeight;
        var overTitleStrip = position.Y >= 0 && position.Y < titleStripHeight;
        var overViewer = position.Y >= titleStripHeight;

        if (overTitleStrip == _mouseOverTitleBarZone && overViewer == _mouseOverViewer)
        {
            return;
        }

        _mouseOverTitleBarZone = overTitleStrip;
        _mouseOverViewer = overViewer;
        UpdateTitleBarVisibility();
    }

    private void MainWindow_MouseLeave(object sender, MouseEventArgs e)
    {
        ReleaseAllPointerButtons();

        if (_mouseOverTitleBarZone || _mouseOverViewer)
        {
            _mouseOverTitleBarZone = false;
            _mouseOverViewer = false;
            UpdateTitleBarVisibility();
        }
    }

    private void TitleBarHitZone_MouseEnter(object sender, MouseEventArgs e) =>
        UpdateTitleBarHoverState(e);

    private void TitleBarHitZone_MouseLeave(object sender, MouseEventArgs e) =>
        UpdateTitleBarHoverState(e);

    private void PointerInputLayer_MouseLeave(object sender, MouseEventArgs e)
    {
        ReleaseAllPointerButtons();
    }

    private void ReleasePointerButtonsIfOutsideViewer(MouseEventArgs e)
    {
        if (_activePointerButtonMask == 0 || IsPointerOverViewer(e))
        {
            return;
        }

        ReleaseAllPointerButtons();
    }

    private bool IsPointerOverViewer(MouseEventArgs e)
    {
        if (ViewerShell.ActualWidth < 1 || ViewerShell.ActualHeight < 1)
        {
            return false;
        }

        var position = e.GetPosition(ViewerShell);
        return position.X >= 0
            && position.X <= ViewerShell.ActualWidth
            && position.Y >= 0
            && position.Y <= ViewerShell.ActualHeight;
    }

    private void ReleaseAllPointerButtons()
    {
        if (_activePointerButtonMask == 0 || !_vncClient.IsConnected)
        {
            _activePointerButtonMask = 0;
            return;
        }

        var x = (int)_lastPointer.X;
        var y = (int)_lastPointer.Y;

        if ((_activePointerButtonMask & 1) != 0)
        {
            _vncClient.SendPointerButton(1, false, x, y);
        }

        if ((_activePointerButtonMask & 4) != 0)
        {
            _vncClient.SendPointerButton(4, false, x, y);
        }

        _activePointerButtonMask = 0;
    }

    private void FrameTimer_Tick(object? sender, EventArgs e)
    {
        var frame = _vncClient.FrameBuffer;
        if (frame is null)
        {
            return;
        }

        if (!ReferenceEquals(FrameImage.Source, frame))
        {
            FrameImage.Source = frame;
            UpdateRotationForFrame(_vncClient.FrameWidth, _vncClient.FrameHeight);
        }

        ScreenViewbox.InvalidateVisual();
    }

    private void UpdateRotationForFrame(int frameWidth, int frameHeight)
    {
        if (frameWidth <= 0 || frameHeight <= 0)
        {
            return;
        }

        var isLandscape = ViewTransformHelper.ShouldAutoRotate(frameWidth, frameHeight);
        if (_lastFrameWasLandscape != isLandscape)
        {
            _manualRotationOverride = false;
            _lastFrameWasLandscape = isLandscape;
        }

        if (!_manualRotationOverride && _settings.AutoRotateLandscape)
        {
            _viewRotation = ViewTransformHelper.ShouldAutoRotate(frameWidth, frameHeight) ? -90 : 0;
        }

        ApplyViewRotation();
        ResizeWindowToFrame(frameWidth, frameHeight);
    }

    private void ApplyViewRotation()
    {
        ViewRotationTransform.Angle = _viewRotation;
        var displaySize = ViewTransformHelper.DisplaySizeForFrame(
            _vncClient.FrameWidth,
            _vncClient.FrameHeight,
            _viewRotation);
        FrameHost.Width = Math.Max(1, displaySize.Width);
        FrameHost.Height = Math.Max(1, displaySize.Height);
    }

    private void ResizeWindowToFrame(int frameWidth, int frameHeight)
    {
        _lockedAspectRatio = ViewTransformHelper.AspectRatioForFrame(frameWidth, frameHeight, _viewRotation);
        UpdateMinSizeForAspect();

        const double maxViewerHeight = 820;
        var viewerHeight = Math.Min(maxViewerHeight, 820);
        var viewerWidth = viewerHeight * _lockedAspectRatio;

        _isAdjustingSize = true;
        try
        {
            Width = Math.Max(MinWidth, viewerWidth + ViewTransformHelper.HorizontalChromeWidth);
            Height = Math.Max(MinHeight, ViewerChromeTop + viewerHeight);
        }
        finally
        {
            _isAdjustingSize = false;
        }

        UpdateRoundedClip();
    }

    private void UpdateMinSizeForAspect()
    {
        const double minViewerShortSide = 320;
        var chromeTop = ViewTransformHelper.TitleBarChromeHeight;
        var horizontalChrome = ViewTransformHelper.HorizontalChromeWidth;
        if (_lockedAspectRatio >= 1.0)
        {
            MinWidth = minViewerShortSide + horizontalChrome;
            MinHeight = chromeTop + minViewerShortSide / _lockedAspectRatio;
        }
        else
        {
            MinHeight = chromeTop + minViewerShortSide;
            MinWidth = minViewerShortSide * _lockedAspectRatio + horizontalChrome;
        }
    }

    private void EnforceLockedAspectRatio(SizeChangedEventArgs e)
    {
        if (_isAdjustingSize || e.NewSize.Width <= 0 || e.NewSize.Height <= 0)
        {
            return;
        }

        if (!e.WidthChanged && !e.HeightChanged)
        {
            return;
        }

        var chromeTop = ViewerChromeTop;
        var widthDelta = Math.Abs(e.NewSize.Width - e.PreviousSize.Width);
        var heightDelta = Math.Abs(e.NewSize.Height - e.PreviousSize.Height);

        _isAdjustingSize = true;
        try
        {
            var horizontalChrome = ViewTransformHelper.HorizontalChromeWidth;
            if (e.WidthChanged && (!e.HeightChanged || widthDelta >= heightDelta))
            {
                var viewerWidth = Math.Max(1, e.NewSize.Width - horizontalChrome);
                Height = chromeTop + (viewerWidth / _lockedAspectRatio);
            }
            else if (e.HeightChanged)
            {
                var viewerHeight = Math.Max(1, e.NewSize.Height - chromeTop);
                Width = viewerHeight * _lockedAspectRatio + horizontalChrome;
            }
        }
        finally
        {
            _isAdjustingSize = false;
        }
    }

    private void UpdateRoundedClip()
    {
        void Apply()
        {
            RoundedWindowChrome.ClearWindowRegion(this);

            if (ViewerShell.ActualWidth < 1 || ViewerShell.ActualHeight < 1)
            {
                return;
            }

            var radius = ViewTransformHelper.CornerRadiusForSize(ViewerShell.ActualWidth, ViewerShell.ActualHeight);
            var corner = new CornerRadius(radius);
            ViewerShell.CornerRadius = corner;
            ScreenClip.CornerRadius = corner;

            RoundedWindowChrome.ApplyRoundedClip(ScreenClip, radius);
            RoundedWindowChrome.ApplyRoundedClip(ScreenHost, radius);
            RoundedWindowChrome.ApplyRoundedClip(ScreenViewbox, radius);

            ApplyTitleBarCornerRadius();
        }

        if (ViewerShell.ActualWidth < 1 || !ViewerShell.IsLoaded)
        {
            Dispatcher.BeginInvoke(Apply, DispatcherPriority.Loaded);
            return;
        }

        Apply();
    }

    private void ShowOverlay(string message, bool busy)
    {
        OverlayPanel.Visibility = Visibility.Visible;
        StatusText.Text = message;
        BusyIndicator.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
    }

    private void HideOverlay()
    {
        OverlayPanel.Visibility = Visibility.Collapsed;
        BusyIndicator.Visibility = Visibility.Collapsed;
    }

    private void SetStatus(string message)
    {
        if (_statusUpdatesPaused || OverlayPanel.Visibility != Visibility.Visible)
        {
            return;
        }

        StatusText.Text = message;
    }

    private Point MapPointerToFrame(Point position)
    {
        var viewboxSize = new Size(ScreenViewbox.ActualWidth, ScreenViewbox.ActualHeight);
        var contentSize = new Size(FrameHost.Width, FrameHost.Height);
        return ViewTransformHelper.MapDisplayToFrame(
            position,
            viewboxSize,
            contentSize,
            _vncClient.FrameWidth,
            _vncClient.FrameHeight,
            _viewRotation,
            fillViewport: false);
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!_vncClient.IsConnected || e.Key == Key.System || VncKeysymMapper.IsTextEntryKey(e.Key))
        {
            return;
        }

        if (VncKeysymMapper.TryGetKeysym(e.Key, out var keysym))
        {
            _vncClient.SendKeyEvent(true, keysym);
            e.Handled = true;
        }
    }

    private void Window_PreviewKeyUp(object sender, KeyEventArgs e)
    {
        if (!_vncClient.IsConnected || e.Key == Key.System || VncKeysymMapper.IsTextEntryKey(e.Key))
        {
            return;
        }

        if (VncKeysymMapper.TryGetKeysym(e.Key, out var keysym))
        {
            _vncClient.SendKeyEvent(false, keysym);
            e.Handled = true;
        }
    }

    private void Window_PreviewTextInput(object sender, TextCompositionEventArgs e)
    {
        if (!_vncClient.IsConnected || string.IsNullOrEmpty(e.Text))
        {
            return;
        }

        foreach (var character in e.Text)
        {
            if (character is < (char)0x20 or > (char)0x7e)
            {
                continue;
            }

            var keysym = (uint)character;
            _vncClient.SendKeyEvent(true, keysym);
            _vncClient.SendKeyEvent(false, keysym);
        }

        e.Handled = true;
    }

    private void FrameImage_MouseMove(object sender, MouseEventArgs e)
    {
        if (!_vncClient.IsConnected)
        {
            return;
        }

        var mapped = MapPointerToFrame(e.GetPosition(ScreenViewbox));
        if ((_activePointerButtonMask & 1) != 0)
        {
            _vncClient.SendPointerEvent(1, (int)mapped.X, (int)mapped.Y);
        }
        else
        {
            _vncClient.SendPointerMove((int)mapped.X, (int)mapped.Y);
        }

        _lastPointer = mapped;
    }

    private void FrameImage_MouseButton(object sender, MouseButtonEventArgs e)
    {
        if (!_vncClient.IsConnected)
        {
            return;
        }

        Focus();
        Keyboard.Focus(this);

        var mapped = MapPointerToFrame(e.GetPosition(ScreenViewbox));
        _lastPointer = mapped;

        var buttonMask = e.ChangedButton switch
        {
            MouseButton.Left => (byte)1,
            MouseButton.Right => (byte)4,
            _ => (byte)0,
        };

        if (buttonMask == 0)
        {
            return;
        }

        if (e.ButtonState == MouseButtonState.Pressed)
        {
            _activePointerButtonMask |= buttonMask;
            _vncClient.SendPointerButton(buttonMask, true, (int)mapped.X, (int)mapped.Y);
        }
        else
        {
            _activePointerButtonMask &= (byte)~buttonMask;
            _vncClient.SendPointerButton(buttonMask, false, (int)mapped.X, (int)mapped.Y);
        }
    }

    private void FrameImage_MouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (!_vncClient.IsConnected)
        {
            return;
        }

        var mapped = _lastPointer;
        var scrollMask = e.Delta > 0 ? (byte)8 : (byte)16;
        _vncClient.SendPointerButton(scrollMask, true, (int)mapped.X, (int)mapped.Y);
        _vncClient.SendPointerButton(scrollMask, false, (int)mapped.X, (int)mapped.Y);
    }

    private void HardwareKeyButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_vncClient.IsConnected || sender is not Button { Tag: string tag })
        {
            return;
        }

        if (!int.TryParse(tag, out var functionKey) || !VncKeysymMapper.TryGetFunctionKeyKeysym(functionKey, out var keysym))
        {
            return;
        }

        _vncClient.SendKeyEvent(true, keysym);
        _vncClient.SendKeyEvent(false, keysym);
    }

    private void UpdateHardwareButtonsEnabled(bool enabled)
    {
        VolumeUpButton.IsEnabled = enabled;
        VolumeDownButton.IsEnabled = enabled;
        SideButtonButton.IsEnabled = enabled;
        HomeButton.IsEnabled = enabled;
        MenuButton.IsEnabled = enabled;
    }

    private void RotateButton_Click(object sender, RoutedEventArgs e)
    {
        _manualRotationOverride = true;
        _viewRotation = Math.Abs(_viewRotation) < 0.01 ? -90 : 0;
        ApplyViewRotation();
        _lockedAspectRatio = ViewTransformHelper.AspectRatioForFrame(
            _vncClient.FrameWidth,
            _vncClient.FrameHeight,
            _viewRotation);
        UpdateMinSizeForAspect();
        ApplyLockedAspectFromWidth();
        UpdateRoundedClip();
    }

    private void ApplyLockedAspectFromWidth()
    {
        if (Width <= 0 || _lockedAspectRatio <= 0)
        {
            return;
        }

        _isAdjustingSize = true;
        try
        {
            var viewerWidth = Math.Max(1, Width - ViewTransformHelper.HorizontalChromeWidth);
            Height = ViewerChromeTop + (viewerWidth / _lockedAspectRatio);
        }
        finally
        {
            _isAdjustingSize = false;
        }
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private void ApplyTitleBarCornerRadius()
    {
        if (TitleBarChrome.ActualWidth < 1 || TitleBarChrome.ActualHeight < 1)
        {
            return;
        }

        var titleRadius = TitleBarChrome.ActualHeight / 2.0;
        TitleBarChrome.CornerRadius = new CornerRadius(titleRadius);
    }

    private void UpdateTitleBarVisibility()
    {
        var show = _mouseOverTitleBarZone || _mouseOverViewer;
        TitleBarChrome.IsHitTestVisible = show;
        FadeTitleBarOpacity(show ? 1 : 0);
    }

    private void FadeTitleBarOpacity(double targetOpacity)
    {
        TitleBarChrome.BeginAnimation(UIElement.OpacityProperty, null);

        var animation = new DoubleAnimation
        {
            To = targetOpacity,
            Duration = TimeSpan.FromMilliseconds(TitleBarFadeDurationMs),
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.HoldEnd,
        };

        TitleBarChrome.BeginAnimation(UIElement.OpacityProperty, animation);
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (IsInteractiveChromeElement(e.OriginalSource as DependencyObject))
        {
            return;
        }

        if (e.ClickCount == 2)
        {
            ToggleAspectFitMaximize();
            return;
        }

        DragMove();
    }

    private static bool IsInteractiveChromeElement(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is Button)
            {
                return true;
            }

            source = VisualTreeHelper.GetParent(source);
        }

        return false;
    }

    private void ToggleAspectFitMaximize()
    {
        if (WindowState == WindowState.Maximized)
        {
            WindowState = WindowState.Normal;
            return;
        }

        var area = SystemParameters.WorkArea;
        var chromeTop = ViewerChromeTop;
        var availableHeight = area.Height - chromeTop;
        var viewerHeight = availableHeight;
        var viewerWidth = viewerHeight * _lockedAspectRatio;
        var horizontalChrome = ViewTransformHelper.HorizontalChromeWidth;
        var maxViewerWidth = Math.Max(1, area.Width - horizontalChrome);
        if (viewerWidth > maxViewerWidth)
        {
            viewerWidth = maxViewerWidth;
            viewerHeight = viewerWidth / _lockedAspectRatio;
        }

        var totalHeight = chromeTop + viewerHeight;
        var totalWidth = viewerWidth + horizontalChrome;

        WindowState = WindowState.Normal;
        _isAdjustingSize = true;
        try
        {
            Left = area.Left + (area.Width - totalWidth) / 2;
            Top = area.Top + (area.Height - totalHeight) / 2;
            Width = totalWidth;
            Height = totalHeight;
        }
        finally
        {
            _isAdjustingSize = false;
        }
    }

    private void DisableSystemWindowRounding()
    {
        if (Environment.OSVersion.Version.Build < 22000)
        {
            return;
        }

        void Apply()
        {
            var windowHandle = new WindowInteropHelper(this).Handle;
            if (windowHandle == IntPtr.Zero)
            {
                return;
            }

            var preference = DwmwcpDoNotRound;
            _ = DwmSetWindowAttribute(windowHandle, DwmwaWindowCornerPreference, ref preference, sizeof(int));
        }

        if (new WindowInteropHelper(this).Handle != IntPtr.Zero)
        {
            Apply();
            return;
        }

        SourceInitialized += (_, _) => Apply();
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
