using System.Windows.Input;

namespace ScreenMirroringViewer.Services;

/// <summary>
/// Maps WPF keys to X11 keysyms (RFB KeyEvent), matching the Screen Mirroring tweak's <c>SMKeysymMap</c>.
/// </summary>
internal static class VncKeysymMapper
{
    public static bool IsTextEntryKey(Key key) =>
        key is >= Key.A and <= Key.Z
            or >= Key.D0 and <= Key.D9
            or Key.Space
            or Key.OemMinus
            or Key.OemPlus
            or Key.OemOpenBrackets
            or Key.OemCloseBrackets
            or Key.OemPipe
            or Key.OemSemicolon
            or Key.OemQuotes
            or Key.OemComma
            or Key.OemPeriod
            or Key.OemQuestion
            or Key.OemTilde;

    public static bool TryGetFunctionKeyKeysym(int functionKeyNumber, out uint keysym)
    {
        if (functionKeyNumber is < 1 or > 24)
        {
            keysym = 0;
            return false;
        }

        keysym = 0xffbe + (uint)(functionKeyNumber - 1);
        return true;
    }

    public static bool TryGetKeysym(Key key, out uint keysym)
    {
        keysym = 0;

        switch (key)
        {
            case Key.Back:
                keysym = 0xff08;
                return true;
            case Key.Tab:
                keysym = 0xff09;
                return true;
            case Key.Return:
                keysym = 0xff0d;
                return true;
            case Key.Escape:
                keysym = 0xff1b;
                return true;
            case Key.Delete:
                keysym = 0xffff;
                return true;
            case Key.Home:
                keysym = 0xff50;
                return true;
            case Key.Left:
                keysym = 0xff51;
                return true;
            case Key.Up:
                keysym = 0xff52;
                return true;
            case Key.Right:
                keysym = 0xff53;
                return true;
            case Key.Down:
                keysym = 0xff54;
                return true;
            case Key.PageUp:
                keysym = 0xff55;
                return true;
            case Key.PageDown:
                keysym = 0xff56;
                return true;
            case Key.End:
                keysym = 0xff57;
                return true;
            case Key.Insert:
                keysym = 0xff63;
                return true;
            case Key.Space:
                keysym = 0x20;
                return true;
            case Key.LeftShift:
                keysym = 0xffe1;
                return true;
            case Key.RightShift:
                keysym = 0xffe2;
                return true;
            case Key.LeftCtrl:
                keysym = 0xffe3;
                return true;
            case Key.RightCtrl:
                keysym = 0xffe4;
                return true;
            case Key.LeftAlt:
                keysym = 0xffe9;
                return true;
            case Key.RightAlt:
                keysym = 0xffea;
                return true;
            case Key.LWin:
                keysym = 0xffeb;
                return true;
            case Key.RWin:
                keysym = 0xffec;
                return true;
            case Key.CapsLock:
            case Key.NumLock:
            case Key.Scroll:
                return false;
        }

        if (key is >= Key.F1 and <= Key.F24)
        {
            keysym = 0xffbe + (uint)(key - Key.F1);
            return true;
        }

        if (key is >= Key.A and <= Key.Z)
        {
            keysym = LetterKeysym(key, 'A', 'a');
            return true;
        }

        if (key is >= Key.D0 and <= Key.D9)
        {
            keysym = DigitKeysym(key);
            return keysym != 0;
        }

        if (TryGetOemKeysym(key, out keysym))
        {
            return true;
        }

        return false;
    }

    private static uint LetterKeysym(Key key, char upperBase, char lowerBase)
    {
        var upper = IsShiftedLetter();
        var ch = (char)(upper ? upperBase + (key - Key.A) : lowerBase + (key - Key.A));
        return ch;
    }

    private static uint DigitKeysym(Key key)
    {
        var shifted = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;
        return key switch
        {
            Key.D0 => shifted ? ')' : '0',
            Key.D1 => shifted ? '!' : '1',
            Key.D2 => shifted ? '@' : '2',
            Key.D3 => shifted ? '#' : '3',
            Key.D4 => shifted ? '$' : '4',
            Key.D5 => shifted ? '%' : '5',
            Key.D6 => shifted ? '^' : '6',
            Key.D7 => shifted ? '&' : '7',
            Key.D8 => shifted ? '*' : '8',
            Key.D9 => shifted ? '(' : '9',
            _ => 0,
        };
    }

    private static bool TryGetOemKeysym(Key key, out uint keysym)
    {
        var shifted = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;
        keysym = key switch
        {
            Key.OemMinus => shifted ? '_' : '-',
            Key.OemPlus => shifted ? '+' : '=',
            Key.OemOpenBrackets => shifted ? '{' : '[',
            Key.OemCloseBrackets => shifted ? '}' : ']',
            Key.OemPipe => shifted ? '|' : '\\',
            Key.OemSemicolon => shifted ? ':' : ';',
            Key.OemQuotes => shifted ? '"' : '\'',
            Key.OemComma => shifted ? '<' : ',',
            Key.OemPeriod => shifted ? '>' : '.',
            Key.OemQuestion => shifted ? '?' : '/',
            Key.OemTilde => shifted ? '~' : '`',
            _ => (char)0,
        };

        return keysym != 0;
    }

    private static bool IsShiftedLetter() =>
        ((Keyboard.Modifiers & ModifierKeys.Shift) != 0) ^ Keyboard.IsKeyToggled(Key.CapsLock);
}
