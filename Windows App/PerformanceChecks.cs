using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Reflection;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// Hidden-control checks: no Shown event, update requests, profile writes, or UI automation.
public static class PerformanceChecks
{
    static int assertions;
    static IEnumerable<Control> Walk(Control root)
    {
        yield return root;
        foreach (Control child in root.Controls)
            foreach (Control nested in Walk(child)) yield return nested;
    }
    static void Assert(bool condition, string label)
    {
        if (!condition) throw new Exception(label);
        assertions++;
    }
    static string Value(object choice) { return (string)choice.GetType().GetField("Value").GetValue(choice); }
    static double Median(List<double> values) { values.Sort(); return values[values.Count / 2]; }

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            bool baseline = args.Contains("--baseline");
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var assembly = Assembly.LoadFrom(System.IO.Path.GetFullPath(args[0]));
            var catalogType = assembly.GetType("ToolDriveOffline.Catalog", true);
            var formType = assembly.GetType("ToolDriveOffline.MainForm", true);
            var optionsType = assembly.GetType("ToolDriveOffline.FilterOptions", true);
            object catalog = catalogType.GetMethod("Load").Invoke(null, null);
            object options = Activator.CreateInstance(optionsType);
            optionsType.GetProperty("Status").SetValue(options, "all", null);
            var filter = catalogType.GetMethod("Filter");
            var filterTimes = new List<double>();
            for (int i = 0; i < 16; i++)
            {
                var clock = Stopwatch.StartNew();
                var result = (ICollection)filter.Invoke(catalog, new object[] { options, new HashSet<string>() });
                clock.Stop();
                Assert(result.Count == 1299, "All-show filtering lost catalog entries");
                if (i > 0) filterTimes.Add(clock.Elapsed.TotalMilliseconds);
            }
            using (var form = (Form)Activator.CreateInstance(formType, new object[] { catalog, null }))
            {
                // Constructing and laying out hidden controls does not raise Shown, so startup
                // networking and persisted-width restoration cannot run in this fixture.
                form.BindingContext = new BindingContext();
                form.PerformLayout();
                var controls = Walk(form).ToList();
                var grid = controls.OfType<DataGridView>().Single();
                var status = controls.OfType<ComboBox>().Single(control => control.AccessibleName == "Recording status");
                var all = status.Items.Cast<object>().Single(choice => Value(choice) == "all");
                var onDrive = status.Items.Cast<object>().Single(choice => Value(choice) == "OTD");
                if (!baseline)
                {
                    Assert(grid.VirtualMode && grid.DataSource == null, "Large-result grid must use virtual rows instead of eager data binding");
                    Assert(grid.Columns.Cast<DataGridViewColumn>().All(column => column.Resizable != DataGridViewTriState.False), "Columns must remain resizable");
                    Assert(grid.Columns.Cast<DataGridViewColumn>().All(column => column.AutoSizeMode != DataGridViewAutoSizeColumnMode.Fill), "Restored column widths must not be stretched by fill sizing");
                    Assert(grid.Columns["Type"].Visible && grid.Columns["Taper"].Visible, "Horizontal scrolling must keep every recording column available");
                }
                var refreshTimes = new List<double>();
                for (int i = 0; i < 12; i++)
                {
                    status.SelectedItem = onDrive;
                    var clock = Stopwatch.StartNew();
                    status.SelectedItem = all;
                    clock.Stop();
                    Assert(grid.RowCount == 1299, "Changing to all statuses must show all 1,299 rows");
                    if (i > 1) refreshTimes.Add(clock.Elapsed.TotalMilliseconds);
                }
                if (!baseline)
                {
                    Assert(Convert.ToString(grid["Date", 0].Value) == "2024-02-03", "Virtual rows must supply full date values");
                    Assert(Convert.ToString(grid["Venue", 0].Value).Contains("Paycom Center"), "Virtual rows must supply the correct venue");
                    grid.CurrentCell = grid["Date", 100];
                    grid.Rows[100].Selected = true;
                    object selected = formType.GetMethod("Selected", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(form, null);
                    Assert(selected != null, "Selecting a virtual row must resolve its show for detail/copy/save actions");
                    status.SelectedItem = onDrive;
                    Assert(grid.RowCount == 759, "Virtual rows must update correctly after narrowing a filter");
                    var widths = new Dictionary<string, int> { { "Date", 180 }, { "Venue", 360 }, { "Location", 260 }, { "Sound", 100 }, { "Sources", 80 }, { "Type", 120 }, { "Taper", 210 } };
                    var apply = formType.GetMethod("ApplyColumnWidths", BindingFlags.Instance | BindingFlags.NonPublic);
                    var capture = formType.GetMethod("CaptureColumnWidths", BindingFlags.Instance | BindingFlags.NonPublic);
                    apply.Invoke(form, new object[] { widths, 144.0 });
                    var scaled = (IDictionary<string, int>)capture.Invoke(form, new object[] { 144.0 });
                    Assert(widths.All(pair => scaled[pair.Key] == pair.Value), "Column widths must survive logical-to-display conversion at 150 percent DPI");
                    apply.Invoke(form, new object[] { scaled, 96.0 });
                    var restored = (IDictionary<string, int>)capture.Invoke(form, new object[] { 96.0 });
                    Assert(widths.All(pair => restored[pair.Key] == pair.Value), "Column widths must retain their size when restored on another DPI");
                }
                var report = new {
                    mode = baseline ? "baseline" : "virtual",
                    allShows = 1299,
                    filterMedianMs = Math.Round(Median(filterTimes), 3),
                    resultRefreshMedianMs = Math.Round(Median(refreshTimes), 3),
                    virtualMode = grid.VirtualMode,
                    assertions = assertions
                };
                Console.WriteLine("PASS hidden-grid and performance checks " + new JavaScriptSerializer().Serialize(report));
            }
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
