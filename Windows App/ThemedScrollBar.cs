using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Windows.Forms;

namespace ToolDriveOffline
{
    // Maximum is the greatest scroll offset, unlike WinForms ScrollBar.Maximum.
    public sealed class ThemedScrollBar : Control
    {
        private Orientation orientation = Orientation.Vertical;
        private int minimum, maximum, value;
        private int largeChange = 1, smallChange = 1;
        private bool dragging, hoverThumb;
        private int dragCoordinate, dragValue;
        private long wheelRemainder;
        public event EventHandler ValueChanged;

        public ThemedScrollBar()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            BackColor = Theme.Background;
            ForeColor = Theme.Muted;
            AccessibleRole = AccessibleRole.ScrollBar;
        }
        protected override Size DefaultSize { get { return new Size(18, 140); } }
        public Orientation Orientation
        {
            get { return orientation; }
            set
            {
                if (value != Orientation.Vertical && value != Orientation.Horizontal) throw new ArgumentOutOfRangeException("value");
                if (orientation == value) return;
                StopDragging(); orientation = value; Invalidate();
            }
        }
        public int Minimum
        {
            get { return minimum; }
            set { if (minimum == value) return; StopDragging(); minimum = value; if (maximum < minimum) maximum = minimum; SetValue(this.value); Invalidate(); }
        }
        public int Maximum
        {
            get { return maximum; }
            set { int next = Math.Max(minimum, value); if (maximum == next) return; StopDragging(); maximum = next; SetValue(this.value); Invalidate(); }
        }
        public int Value { get { return value; } set { SetValue(value); } }
        public int LargeChange
        {
            get { return largeChange; }
            set { int next = Math.Max(1, value); if (largeChange == next) return; StopDragging(); largeChange = next; Invalidate(); }
        }
        public int SmallChange { get { return smallChange; } set { smallChange = Math.Max(1, value); } }
        public void SetRange(int maximum, int viewport)
        {
            int next = Math.Max(0, maximum), page = Math.Max(1, viewport);
            if (minimum != 0 || this.maximum != next || largeChange != page) StopDragging();
            minimum = 0; this.maximum = next; largeChange = page;
            SetValue(value); Invalidate();
        }
        public void ScrollBy(int delta) { SetValue((int)Math.Max(minimum, Math.Min((long)maximum, (long)value + delta))); }
        public void ScrollToStart() { Value = minimum; }
        public void ScrollToEnd() { Value = maximum; }

        private int Logical(int pixels) { return Math.Max(1, (int)Math.Round(pixels * Math.Max(1, DeviceDpi) / 96.0)); }
        private Rectangle TrackBounds
        {
            get
            {
                int inset = Logical(2);
                return Width <= inset * 2 || Height <= inset * 2 ? Rectangle.Empty : new Rectangle(inset, inset, Width - inset * 2, Height - inset * 2);
            }
        }
        public Rectangle ThumbBounds
        {
            get
            {
                Rectangle track = TrackBounds;
                if (track.IsEmpty) return Rectangle.Empty;
                int extent = orientation == Orientation.Vertical ? track.Height : track.Width;
                long range = (long)maximum - minimum;
                int thumb = range == 0 ? extent : (int)Math.Round(extent * ((double)largeChange / (range + (double)largeChange)));
                thumb = Math.Min(extent, Math.Max(Logical(24), thumb));
                int travel = extent - thumb;
                int offset = range == 0 ? 0 : (int)Math.Round(travel * (((long)value - minimum) / (double)range));
                return orientation == Orientation.Vertical ? new Rectangle(track.Left, track.Top + offset, track.Width, thumb) : new Rectangle(track.Left + offset, track.Top, thumb, track.Height);
            }
        }
        private void SetValue(int next)
        {
            next = Math.Max(minimum, Math.Min(maximum, next));
            if (value == next) return;
            value = next; Invalidate();
            EventHandler handler = ValueChanged;
            if (handler != null) handler(this, EventArgs.Empty);
            if (IsHandleCreated) AccessibilityNotifyClients(AccessibleEvents.ValueChange, -1);
        }
        private int Coordinate(Point point) { return orientation == Orientation.Vertical ? point.Y : point.X; }
        private void StopDragging() { dragging = false; if (Capture) Capture = false; }
        private void ScrollToNumber(double next)
        {
            if (next <= minimum) Value = minimum;
            else if (next >= maximum) Value = maximum;
            else Value = (int)Math.Round(next, MidpointRounding.AwayFromZero);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(Theme.Background);
            Rectangle track = TrackBounds, thumb = ThumbBounds;
            if (track.IsEmpty) return;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush brush = new SolidBrush(Theme.Panel)) e.Graphics.FillRectangle(brush, ClientRectangle);
            using (SolidBrush brush = new SolidBrush(!Enabled || maximum == minimum ? Theme.Line : dragging || hoverThumb || Focused ? Theme.Amber : Theme.Muted))
            using (GraphicsPath shape = Rounded(thumb)) e.Graphics.FillPath(brush, shape);
            if (Focused && Enabled)
            {
                Rectangle cue = ClientRectangle; cue.Inflate(-1, -1);
                if (cue.Width > 0 && cue.Height > 0)
                    using (Pen pen = new Pen(Theme.Amber)) { pen.DashStyle = DashStyle.Dot; e.Graphics.DrawRectangle(pen, cue); }
            }
            base.OnPaint(e);
        }
        private static GraphicsPath Rounded(Rectangle rectangle)
        {
            GraphicsPath path = new GraphicsPath();
            int diameter = Math.Min(rectangle.Width, rectangle.Height);
            if (diameter <= 1) { path.AddRectangle(rectangle); return path; }
            path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
            path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
            path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0, 90);
            path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure(); return path;
        }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (!Enabled || e.Button != MouseButtons.Left) return;
            Focus();
            Rectangle thumb = ThumbBounds;
            if (thumb.IsEmpty || maximum == minimum) return;
            if (thumb.Contains(e.Location))
            {
                dragging = true; dragCoordinate = Coordinate(e.Location); dragValue = value; Capture = true;
            }
            else ScrollBy(Coordinate(e.Location) < (orientation == Orientation.Vertical ? thumb.Top : thumb.Left) ? -largeChange : largeChange);
            Invalidate();
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            bool hover = ThumbBounds.Contains(e.Location);
            if (hover != hoverThumb) { hoverThumb = hover; Invalidate(); }
            if (!dragging) return;
            Rectangle track = TrackBounds, thumb = ThumbBounds;
            int travel = orientation == Orientation.Vertical ? track.Height - thumb.Height : track.Width - thumb.Width;
            if (travel > 0) ScrollToNumber(dragValue + ((long)Coordinate(e.Location) - dragCoordinate) * (((long)maximum - minimum) / (double)travel));
        }
        protected override void OnMouseUp(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { StopDragging(); Invalidate(); } base.OnMouseUp(e); }
        protected override void OnMouseCaptureChanged(EventArgs e) { if (!Capture) { dragging = false; Invalidate(); } base.OnMouseCaptureChanged(e); }
        protected override void OnMouseLeave(EventArgs e) { hoverThumb = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseWheel(MouseEventArgs e)
        {
            if (Enabled)
            {
                wheelRemainder += e.Delta;
                int notch = Math.Max(1, SystemInformation.MouseWheelScrollDelta);
                long steps = wheelRemainder / notch; wheelRemainder %= notch;
                int lines = SystemInformation.MouseWheelScrollLines;
                double units = lines < 0 ? largeChange : (double)Math.Max(1, lines) * smallChange;
                ScrollToNumber(value - steps * units);
                HandledMouseEventArgs handled = e as HandledMouseEventArgs;
                if (handled != null) handled.Handled = true;
            }
            base.OnMouseWheel(e);
        }
        protected override bool IsInputKey(Keys keyData)
        {
            Keys key = keyData & Keys.KeyCode;
            return key == Keys.Up || key == Keys.Down || key == Keys.Left || key == Keys.Right || key == Keys.Home || key == Keys.End || key == Keys.PageUp || key == Keys.PageDown || base.IsInputKey(keyData);
        }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            bool handled = Enabled;
            if (Enabled)
            {
                switch (e.KeyCode)
                {
                    case Keys.Up: case Keys.Left: ScrollBy(-smallChange); break;
                    case Keys.Down: case Keys.Right: ScrollBy(smallChange); break;
                    case Keys.PageUp: ScrollBy(-largeChange); break;
                    case Keys.PageDown: ScrollBy(largeChange); break;
                    case Keys.Home: ScrollToStart(); break;
                    case Keys.End: ScrollToEnd(); break;
                    default: handled = false; break;
                }
            }
            if (handled) { e.Handled = true; e.SuppressKeyPress = true; }
            base.OnKeyDown(e);
        }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
        protected override void OnSizeChanged(EventArgs e) { StopDragging(); Invalidate(); base.OnSizeChanged(e); }
        protected override void OnFontChanged(EventArgs e) { Invalidate(); base.OnFontChanged(e); }
        protected override void OnEnabledChanged(EventArgs e) { if (!Enabled) StopDragging(); Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnDpiChangedAfterParent(EventArgs e) { StopDragging(); Invalidate(); base.OnDpiChangedAfterParent(e); }
        protected override AccessibleObject CreateAccessibilityInstance() { return new ScrollAccessibleObject(this); }
        protected override void Dispose(bool disposing) { if (disposing) StopDragging(); base.Dispose(disposing); }

        private sealed class ScrollAccessibleObject : ControlAccessibleObject
        {
            private readonly ThemedScrollBar owner;
            public ScrollAccessibleObject(ThemedScrollBar owner) : base(owner) { this.owner = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.ScrollBar; } }
            public override string Name { get { return String.IsNullOrEmpty(owner.AccessibleName) ? (owner.Orientation == Orientation.Vertical ? "Vertical scroll bar" : "Horizontal scroll bar") : owner.AccessibleName; } set { owner.AccessibleName = value; } }
            public override string Value
            {
                get { return owner.Value.ToString(CultureInfo.InvariantCulture); }
                set { int next; if (Int32.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out next)) owner.Value = next; }
            }
            public override string DefaultAction { get { return "Scroll forward"; } }
            public override void DoDefaultAction() { if (owner.Enabled) owner.ScrollBy(owner.SmallChange); }
            public override AccessibleStates State { get { return base.State | AccessibleStates.Focusable | (owner.Focused ? AccessibleStates.Focused : AccessibleStates.None) | (!owner.Enabled ? AccessibleStates.Unavailable : AccessibleStates.None); } }
        }
    }
}
