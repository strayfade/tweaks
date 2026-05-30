using System.Windows;
using System.Windows.Input;

namespace ScreenMirroringViewer;

public partial class PasswordDialog : Window
{
    public string Password => PasswordBox.Password;

    public PasswordDialog(string deviceName)
    {
        InitializeComponent();
        DeviceNameText.Text = deviceName;
        PasswordBox.Focus();
    }

    private void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(PasswordBox.Password))
        {
            StatusText.Text = "Enter the VNC password from Screen Mirroring settings.";
            return;
        }

        DialogResult = true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void PasswordBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            ConnectButton_Click(sender, e);
        }
    }
}
