using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;

// A separate console check executable. Not included in the portable app ZIP.
public static class FilterChecks
{
    static Type optionsType;
    static object catalog;
    static MethodInfo filter;
    static int passed;

    static object Get(object target, string name)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.IgnoreCase;
        var property = target.GetType().GetProperty(name, flags);
        if (property != null) return property.GetValue(target, null);
        var field = target.GetType().GetField(name, flags);
        if (field != null) return field.GetValue(target);
        throw new Exception("Missing readable member: " + name);
    }

    static void Set(object target, string name, object value)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.IgnoreCase;
        var property = target.GetType().GetProperty(name, flags);
        if (property != null) { property.SetValue(target, Convert.ChangeType(value, property.PropertyType), null); return; }
        var field = target.GetType().GetField(name, flags);
        if (field != null) { field.SetValue(target, Convert.ChangeType(value, field.FieldType)); return; }
        throw new Exception("Missing writable option: " + name);
    }

    static object Options(params object[] pairs)
    {
        var options = Activator.CreateInstance(optionsType);
        for (int i = 0; i < pairs.Length; i += 2) Set(options, (string)pairs[i], pairs[i + 1]);
        return options;
    }

    static List<object> Matches(object options, ISet<string> saved)
    {
        return ((IEnumerable)filter.Invoke(catalog, new object[] { options, saved })).Cast<object>().ToList();
    }

    static List<object> Check(string label, int shows, int sources, params object[] pairs)
    {
        var rows = Matches(Options(pairs), new HashSet<string>());
        int sourceCount = rows.Sum(row => ((IEnumerable)Get(row, "Sources")).Cast<object>().Count());
        Assert(rows.Count == shows && sourceCount == sources,
            label + ": expected " + shows + "/" + sources + ", got " + rows.Count + "/" + sourceCount);
        Console.WriteLine("PASS " + label + ": " + rows.Count + " shows, " + sourceCount + " sources");
        return rows;
    }

    static void Assert(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        passed++;
    }

    static string Date(object match) { return Convert.ToString(Get(Get(match, "Show"), "date")); }

    public static int Main(string[] args)
    {
        try
        {
            var assembly = Assembly.LoadFrom(Path.GetFullPath(args[0]));
            var catalogType = assembly.GetType("ToolDriveOffline.Catalog", true);
            optionsType = assembly.GetType("ToolDriveOffline.FilterOptions", true);
            catalog = catalogType.GetMethod("Load", BindingFlags.Public | BindingFlags.Static).Invoke(null, null);
            filter = catalogType.GetMethod("Filter", BindingFlags.Public | BindingFlags.Instance);
            var defaults = Check("Default on-drive catalog", 759, 1342);
            Check("Sound rating >=9", 142, 167, "MinimumRating", 9.0);
            Check("Soundboard rating >=9", 18, 19, "MinimumRating", 9.0, "RecordingType", "soundboard");
            var audience = Matches(Options("MinimumRating", 9.0, "RecordingType", "audience"), new HashSet<string>());
            Assert(!audience.Any(row => Date(row) == "1993-06-11"), "Audience filter borrowed soundboard rating");
            var taperSearch = Matches(Options("MinimumRating", 9.0, "Search", "1993-06-11 Stephane"), new HashSet<string>());
            Assert(taperSearch.Count == 0, "Taper search borrowed another source's rating");
            var iem = Matches(Options("MinimumRating", 9.0, "RecordingType", "IEM"), new HashSet<string>());
            Assert(!iem.Any(row => Date(row) == "2006-09-21"), "IEM filter borrowed audience rating");
            Check("Unrated on-drive sources", 339, 547, "RatingMode", "unrated");
            Check("All catalog statuses", 1299, 2694, "Status", "all");
            Check("Unknown recording placeholders", 124, 124, "Status", "Unknown");
            Check("Audience rating >=8 during 2002", 23, 28, "MinimumRating", 8.0,
                "RecordingType", "audience", "FromYear", "2002", "ToYear", "2002");
            Check("Reversed year range", 0, 0, "FromYear", "2024", "ToYear", "1991");
            var search = Matches(Options("Search", "1991-09-05"), new HashSet<string>());
            Assert(search.Count == 1 && Date(search[0]) == "1991-09-05", "Exact date search failed");
            var confirmed = Matches(Options("Status", "Confirmed", "RatingMode", "rated"), new HashSet<string>());
            Assert(confirmed.Count == 1 && Date(confirmed[0]) == "2006-09-07", "Confirmed rating filter failed");
            var firstId = Convert.ToString(Get(Get(defaults[0], "Show"), "id"));
            var saved = Matches(Options("SavedOnly", true), new HashSet<string>(new string[] { firstId }));
            Assert(saved.Count == 1 && Convert.ToString(Get(Get(saved[0], "Show"), "id")) == firstId, "Saved-only filter failed");
            Console.WriteLine("PASS " + passed + " assertions; embedded catalog loaded with no sidecar data.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            return 1;
        }
    }
}
