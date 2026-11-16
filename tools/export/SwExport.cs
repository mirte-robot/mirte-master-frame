// Exports manufacturing files (STL, STEP, DXF) for the parts of the MIRTE Master assembly.
// Compiled at run time by Export-Parts.ps1 (Windows PowerShell 5.1, C# 5 -- keep syntax simple:
// no string interpolation, no ?. operator, no out var).
//
// Never saves a CAD document. To export a part configuration that is not the active one, it switches the part's active
// configuration in memory; at the end it closes the documents from the solidworks folder (discarding only those
// switches -- it refuses to start if anything has unsaved changes) and reopens the assembly.

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using SolidWorks.Interop.sldworks;
using SolidWorks.Interop.swconst;

namespace MirteExport
{
    public class ExportOptions
    {
        public string RepoRoot;
        public string AssemblyPath;
        public string OutDir;
        public string PropertyName = "Export";            // custom property that overrides the rules: print | laser | none
        public string[] PurchasedFolders = new string[0];  // repo-relative folders with bought / reference parts -> none
        public string[] ExcludeFiles = new string[0];      // "path" or "path:config" -> none
        public string[] LaserFiles = new string[0];        // "path" or "path:config" -> laser (in addition to sheet metal parts)
        public string[] PrintFiles = new string[0];        // "path" or "path:config" -> print (overrides folder and sheet-metal rules)
        public bool ListOnly;
        // Output groups: a part goes to the group of the nearest enclosing sub-assembly listed here, else DefaultGroup.
        // Parallel arrays: GroupAssemblies[i] (repo-relative .SLDASM) belongs to GroupNames[i].
        public string[] GroupNames = new string[0];
        public string[] GroupAssemblies = new string[0];
        public string DefaultGroup = "base";
        // Explicit group per part, overriding the sub-assembly rule: GroupOverrideFiles[i] ("path" or "path:config") -> GroupOverrideNames[i].
        public string[] GroupOverrideFiles = new string[0];
        public string[] GroupOverrideNames = new string[0];
    }

    public class ExportItem
    {
        public string Path;       // full path of the part file
        public string RelPath;    // repo-relative, forward slashes
        public string Config;
        public string Group;      // file-name prefix, e.g. "base" | "arm" | "gripper"
        public string Kind;       // "print" | "laser" | "none"
        public string Reason;
        public bool SheetMetal;
        public string BaseName;
        public List<string> Components = new List<string>();
        public List<string> Outputs = new List<string>();  // repo-relative output files
        public List<string> Errors = new List<string>();
    }

    public class ExportResult
    {
        public List<ExportItem> Items = new List<ExportItem>();
        public List<string> Errors = new List<string>();     // errors that stopped the export
        public List<string> Notes = new List<string>();
        public string SolidWorksRevision;
    }

    public static class Exporter
    {
        static ISldWorks Connect()
        {
            object o;
            try { o = Marshal.GetActiveObject("SldWorks.Application"); }
            catch (COMException) { return null; }
            return (ISldWorks)o;
        }

        static string Rel(string repo, string full)
        {
            string r = full;
            string root = repo.TrimEnd('\\') + "\\";
            if (full.StartsWith(root, StringComparison.OrdinalIgnoreCase)) r = full.Substring(root.Length);
            return r.Replace('\\', '/');
        }

        // Entry "path" matches every configuration of that file, "path:config" only that configuration.
        static bool Listed(string[] list, string rel, string cfg)
        {
            if (list == null) return false;
            foreach (string s in list)
            {
                if (string.IsNullOrEmpty(s)) continue;
                string e = s.Replace('\\', '/');
                if (string.Equals(e, rel, StringComparison.OrdinalIgnoreCase)) return true;
                if (string.Equals(e, rel + ":" + cfg, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        static string ReadProp(ModelDoc2 m, string cfg, string name)
        {
            foreach (string c in new string[] { cfg, "" })
            {
                CustomPropertyManager pm = m.Extension.get_CustomPropertyManager(c);
                if (pm == null) continue;
                string val, resolved; bool wasResolved, linked;
                int st = pm.Get6(name, false, out val, out resolved, out wasResolved, out linked);
                if (st != (int)swCustomInfoGetResult_e.swCustomInfoGetResult_NotPresent && !string.IsNullOrEmpty(resolved))
                    return resolved.Trim().ToLowerInvariant();
            }
            return "";
        }

        static bool HasFlatPattern(ModelDoc2 m)
        {
            Feature f = (Feature)m.FirstFeature();
            while (f != null)
            {
                if (f.GetTypeName2() == "FlatPattern") return true;
                f = (Feature)f.GetNextFeature();
            }
            return false;
        }

        static string Safe(string s)
        {
            foreach (char c in Path.GetInvalidFileNameChars()) s = s.Replace(c, '_');
            return s;
        }

        public static ExportResult Run(ExportOptions opt)
        {
            var r = new ExportResult();
            ISldWorks sw = Connect();
            if (sw == null) { r.Errors.Add("SolidWorks is not running. Start SolidWorks and run the export again."); return r; }
            r.SolidWorksRevision = sw.RevisionNumber();

            string full = Path.GetFullPath(opt.AssemblyPath);
            string cadFolder = Path.GetDirectoryName(full).TrimEnd('\\') + "\\";

            // Refuse to start if anything from the CAD folder has unsaved changes: the exports must match the files on disk,
            // and the clean-up at the end closes those documents without saving.
            var dirty = new List<string>();
            var windows = new List<string>();   // documents from the CAD folder with an open window; reopened after the clean-up
            ModelDoc2 activeDoc = (ModelDoc2)sw.ActiveDoc;
            string activePath = activeDoc == null ? null : activeDoc.GetPathName();
            object[] open = (object[])sw.GetDocuments();
            ModelDoc2 top = null;
            if (open != null)
                foreach (ModelDoc2 d in open)
                {
                    string p = d.GetPathName();
                    if (string.IsNullOrEmpty(p)) continue;
                    if (string.Equals(Path.GetFullPath(p), full, StringComparison.OrdinalIgnoreCase)) top = d;
                    if (!p.StartsWith(cadFolder, StringComparison.OrdinalIgnoreCase)) continue;
                    if (d.GetSaveFlag()) dirty.Add(Path.GetFileName(p));
                    if (d.Visible) windows.Add(p);
                }
            if (dirty.Count > 0)
            {
                r.Errors.Add("These documents have unsaved changes: " + string.Join(", ", dirty.ToArray()) +
                    ". Save them (or close them without saving) and run the export again. Nothing was exported.");
                return r;
            }

            if (top == null)
            {
                int err = 0, warn = 0;
                top = (ModelDoc2)sw.OpenDoc6(full, (int)swDocumentTypes_e.swDocASSEMBLY, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref err, ref warn);
                if (top == null) { r.Errors.Add("Could not open the assembly " + full + " (error code " + err + ")."); return r; }
            }

            Collect(top, opt, r);
            if (opt.ListOnly || r.Errors.Count > 0) return r;

            bool changed = false;
            var saved = SetExportPreferences(sw);
            try
            {
                foreach (ExportItem it in r.Items)
                {
                    if (it.Kind == "none") continue;
                    if (ExportOne(sw, it, opt)) changed = true;
                }
            }
            finally
            {
                RestorePreferences(sw, saved);
            }

            if (changed) Reload(sw, full, cadFolder, windows, activePath, r);
            return r;
        }

        // Walk every resolved part component and decide what to export per (file, configuration).
        static void Collect(ModelDoc2 top, ExportOptions opt, ExportResult r)
        {
            var byKey = new Dictionary<string, ExportItem>(StringComparer.OrdinalIgnoreCase);
            object[] comps = (object[])((AssemblyDoc)top).GetComponents(false);
            if (comps == null) return;
            foreach (Component2 c in comps)
            {
                if (c.IsSuppressed() || c.IsEnvelope()) continue;
                ModelDoc2 m = (ModelDoc2)c.GetModelDoc2();
                if (m == null)
                {
                    string p0 = c.GetPathName();
                    if (p0 != null && p0.EndsWith(".sldprt", StringComparison.OrdinalIgnoreCase))
                        r.Errors.Add("Component " + c.Name2 + " is not loaded (lightweight or missing): " + p0 + ". Resolve it and run again.");
                    continue;
                }
                if (m.GetType() != (int)swDocumentTypes_e.swDocPART) continue;

                string path = m.GetPathName();
                string cfg = c.ReferencedConfiguration;
                string group = GroupOf(c, Rel(opt.RepoRoot, path), cfg, opt);
                string key = group + "|" + path + "|" + cfg;
                ExportItem it;
                if (byKey.TryGetValue(key, out it)) { it.Components.Add(c.Name2); continue; }

                it = new ExportItem();
                it.Path = path; it.RelPath = Rel(opt.RepoRoot, path); it.Config = cfg; it.Group = group;
                it.Components.Add(c.Name2);
                it.SheetMetal = HasFlatPattern(m);
                Classify(m, c, it, opt);
                byKey[key] = it;
                r.Items.Add(it);
            }

            // Output names: <group>_<file> or, when several configurations of one file are exported, <group>_<file>-<config>.
            var cfgCount = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (ExportItem it in r.Items)
                if (it.Kind != "none") { string k = it.Group + "|" + it.Path; int n; cfgCount.TryGetValue(k, out n); cfgCount[k] = n + 1; }
            var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (ExportItem it in r.Items)
            {
                if (it.Kind == "none") continue;
                string b = it.Group + "_" + Path.GetFileNameWithoutExtension(it.Path);
                if (cfgCount[it.Group + "|" + it.Path] > 1) b += "-" + it.Config;
                b = Safe(b);
                string u = b; int i = 2;
                while (!used.Add(u)) u = b + "_" + (i++);
                it.BaseName = u;
            }
        }

        // Group from group_overrides, else of the nearest enclosing sub-assembly listed in the config, else DefaultGroup.
        static string GroupOf(Component2 c, string rel0, string cfg, ExportOptions opt)
        {
            for (int i = 0; i < opt.GroupOverrideFiles.Length; i++)
                if (Listed(new string[] { opt.GroupOverrideFiles[i] }, rel0, cfg)) return opt.GroupOverrideNames[i];
            Component2 p = (Component2)c.GetParent();
            while (p != null)
            {
                string rel = Rel(opt.RepoRoot, p.GetPathName());
                for (int i = 0; i < opt.GroupAssemblies.Length; i++)
                    if (string.Equals(opt.GroupAssemblies[i].Replace('\\', '/'), rel, StringComparison.OrdinalIgnoreCase))
                        return opt.GroupNames[i];
                p = (Component2)p.GetParent();
            }
            return opt.DefaultGroup;
        }

        static void Classify(ModelDoc2 m, Component2 c, ExportItem it, ExportOptions opt)
        {
            string prop = ReadProp(m, it.Config, opt.PropertyName);
            if (prop == "print" || prop == "laser" || prop == "none")
            {
                it.Kind = prop; it.Reason = "custom property " + opt.PropertyName + "=" + prop; return;
            }
            if (prop != "") it.Errors.Add("Unknown value '" + prop + "' for custom property " + opt.PropertyName + " (use print, laser or none); ignored.");

            if (c.ExcludeFromBOM) { it.Kind = "none"; it.Reason = "excluded from BOM"; return; }
            if (Listed(opt.ExcludeFiles, it.RelPath, it.Config)) { it.Kind = "none"; it.Reason = "exclude_files"; return; }
            if (Listed(opt.PrintFiles, it.RelPath, it.Config)) { it.Kind = "print"; it.Reason = "print_files"; return; }
            if (Listed(opt.LaserFiles, it.RelPath, it.Config)) { it.Kind = "laser"; it.Reason = "laser_files"; return; }
            foreach (string f in opt.PurchasedFolders)
            {
                string pf = f.Replace('\\', '/').TrimEnd('/') + "/";
                if (it.RelPath.StartsWith(pf, StringComparison.OrdinalIgnoreCase)) { it.Kind = "none"; it.Reason = "purchased folder " + f; return; }
            }
            if (!it.RelPath.Contains("/") || it.RelPath.Contains(":"))
            {
                it.Kind = "none"; it.Reason = "file outside the repository"; return;
            }
            if (it.SheetMetal) { it.Kind = "laser"; it.Reason = "sheet metal (has a flat pattern)"; return; }
            it.Kind = "print"; it.Reason = "custom part (default)";
        }

        class SavedPrefs { public Dictionary<int, bool> T = new Dictionary<int, bool>(); public Dictionary<int, int> I = new Dictionary<int, int>(); }

        static SavedPrefs SetExportPreferences(ISldWorks sw)
        {
            var s = new SavedPrefs();
            SetT(sw, s, (int)swUserPreferenceToggle_e.swSTLBinaryFormat, true);
            SetT(sw, s, (int)swUserPreferenceToggle_e.swSTLDontTranslateToPositive, true);   // keep part coordinates
            SetI(sw, s, (int)swUserPreferenceIntegerValue_e.swExportStlUnits, (int)swLengthUnit_e.swMM);
            SetI(sw, s, (int)swUserPreferenceIntegerValue_e.swSTLQuality, (int)swSTLQuality_e.swSTLQuality_Fine);
            SetI(sw, s, (int)swUserPreferenceIntegerValue_e.swStepAP, 214);
            return s;
        }
        static void SetT(ISldWorks sw, SavedPrefs s, int id, bool v) { s.T[id] = sw.GetUserPreferenceToggle(id); sw.SetUserPreferenceToggle(id, v); }
        static void SetI(ISldWorks sw, SavedPrefs s, int id, int v) { s.I[id] = sw.GetUserPreferenceIntegerValue(id); sw.SetUserPreferenceIntegerValue(id, v); }
        static void RestorePreferences(ISldWorks sw, SavedPrefs s)
        {
            foreach (var kv in s.T) sw.SetUserPreferenceToggle(kv.Key, kv.Value);
            foreach (var kv in s.I) sw.SetUserPreferenceIntegerValue(kv.Key, kv.Value);
        }

        // Exports one part configuration. Returns true if it switched the part's active configuration.
        static bool ExportOne(ISldWorks sw, ExportItem it, ExportOptions opt)
        {
            bool switched = false;
            int err = 0, warn = 0;
            ModelDoc2 before = (ModelDoc2)sw.GetOpenDocumentByName(it.Path);
            bool wasVisible = before != null && before.Visible;
            ModelDoc2 m = (ModelDoc2)sw.OpenDoc6(it.Path, (int)swDocumentTypes_e.swDocPART, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref err, ref warn);
            if (m == null) { it.Errors.Add("Could not open the part (error code " + err + ")."); return false; }
            sw.ActivateDoc3(m.GetTitle(), false, (int)swRebuildOnActivation_e.swDontRebuildActiveDoc, ref err);

            string active = ((Configuration)m.GetActiveConfiguration()).Name;
            if (!string.Equals(active, it.Config, StringComparison.Ordinal))
            {
                if (!m.ShowConfiguration2(it.Config)) { it.Errors.Add("Could not activate configuration " + it.Config + "."); return false; }
                switched = true;
                m.EditRebuild3();
            }

            Save(m, it, opt, "step", ".STEP");
            if (it.Kind == "print") Save(m, it, opt, "stl", ".STL");
            if (it.Kind == "laser") Dxf(m, it, opt);

            if (switched) { m.ShowConfiguration2(active); m.EditRebuild3(); }
            if (!wasVisible) sw.CloseDoc(m.GetTitle());   // a part used by the open assembly stays loaded; only its window closes
            return switched;
        }

        static void Save(ModelDoc2 m, ExportItem it, ExportOptions opt, string sub, string ext)
        {
            string dir = Path.Combine(opt.OutDir, sub);
            Directory.CreateDirectory(dir);
            string file = Path.Combine(dir, it.BaseName + ext);
            int err = 0, warn = 0;
            bool ok = m.Extension.SaveAs(file, (int)swSaveAsVersion_e.swSaveAsCurrentVersion,
                (int)(swSaveAsOptions_e.swSaveAsOptions_Silent | swSaveAsOptions_e.swSaveAsOptions_Copy), null, ref err, ref warn);
            if (ok && File.Exists(file)) it.Outputs.Add(Rel(opt.RepoRoot, file));
            else it.Errors.Add(ext.TrimStart('.') + " export failed (error " + err + ", warning " + warn + ").");
        }

        static void Dxf(ModelDoc2 m, ExportItem it, ExportOptions opt)
        {
            string dir = Path.Combine(opt.OutDir, "dxf");
            Directory.CreateDirectory(dir);
            string file = Path.Combine(dir, it.BaseName + ".DXF");
            PartDoc p = (PartDoc)m;
            bool ok;
            if (it.SheetMetal)
            {
                // Flat pattern, geometry only (no bend lines, sketches or hidden edges).
                ok = p.ExportToDWG2(file, m.GetPathName(), (int)swExportToDWG_e.swExportToDWG_ExportSheetMetal, true, null, false, false, 1, null);
            }
            else
            {
                // Plate modelled as an ordinary solid: export the outline (with all holes) of its largest planar face.
                Face2 best = null; double bestArea = 0;
                object[] bodies = (object[])p.GetBodies2((int)swBodyType_e.swSolidBody, true);
                if (bodies != null)
                    foreach (Body2 b in bodies)
                    {
                        object[] faces = (object[])b.GetFaces();
                        if (faces == null) continue;
                        foreach (Face2 f in faces)
                        {
                            Surface s = (Surface)f.GetSurface();
                            if (s == null || !s.IsPlane()) continue;
                            double a = f.GetArea();
                            if (a > bestArea) { bestArea = a; best = f; }
                        }
                    }
                if (best == null) { it.Errors.Add("DXF export failed: no planar face found."); return; }
                if (bodies.Length > 1) it.Errors.Add("Part has " + bodies.Length + " bodies; the DXF only contains the largest planar face.");
                m.ClearSelection2(true);
                ((Entity)best).Select4(false, null);
                ok = p.ExportToDWG2(file, m.GetPathName(), (int)swExportToDWG_e.swExportToDWG_ExportSelectedFacesOrLoops, true, null, false, false, 0, null);
                m.ClearSelection2(true);
            }
            if (ok && File.Exists(file)) it.Outputs.Add(Rel(opt.RepoRoot, file));
            else it.Errors.Add("DXF export failed.");
        }

        // Discard the in-memory configuration switches: close the documents from the CAD folder, then reopen the assembly
        // and every other document that had a window open before, and re-activate the document that was active.
        // Only reached when nothing had unsaved changes at the start.
        static void Reload(ISldWorks sw, string assemblyPath, string folder, List<string> windows, string activePath, ExportResult r)
        {
            sw.CloseDoc(assemblyPath);
            for (int pass = 0; pass < 2; pass++)
            {
                object[] docs = (object[])sw.GetDocuments();
                if (docs == null) break;
                foreach (ModelDoc2 d in docs)
                {
                    string p = d.GetPathName();
                    if (string.IsNullOrEmpty(p) || !p.StartsWith(folder, StringComparison.OrdinalIgnoreCase)) continue;
                    sw.CloseDoc(pass == 0 ? p : d.GetTitle());
                }
            }
            int err = 0, warn = 0;
            ModelDoc2 top = (ModelDoc2)sw.OpenDoc6(assemblyPath, (int)swDocumentTypes_e.swDocASSEMBLY, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref err, ref warn);
            if (top == null) r.Notes.Add("Could not reopen " + assemblyPath + " after the export (error " + err + "); open it manually.");

            foreach (string p in windows)
            {
                if (string.Equals(p, assemblyPath, StringComparison.OrdinalIgnoreCase)) continue;
                string ext = Path.GetExtension(p).ToLowerInvariant();
                int type = ext == ".sldasm" ? (int)swDocumentTypes_e.swDocASSEMBLY : ext == ".slddrw" ? (int)swDocumentTypes_e.swDocDRAWING : (int)swDocumentTypes_e.swDocPART;
                ModelDoc2 d = (ModelDoc2)sw.OpenDoc6(p, type, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref err, ref warn);
                if (d == null) r.Notes.Add("Could not reopen " + Path.GetFileName(p) + " (error " + err + "); open it manually.");
                else d.Visible = true;   // OpenDoc6 on a document already loaded by the assembly does not show its window
            }
            if (!string.IsNullOrEmpty(activePath))
            {
                ModelDoc2 a = (ModelDoc2)sw.GetOpenDocumentByName(activePath);
                if (a != null) sw.ActivateDoc3(a.GetTitle(), false, (int)swRebuildOnActivation_e.swDontRebuildActiveDoc, ref err);
            }
            r.Notes.Add("Part configurations were switched for the export; the open documents from the CAD folder were closed without saving and reopened ("
                + windows.Count + " window(s)).");
        }
    }
}
