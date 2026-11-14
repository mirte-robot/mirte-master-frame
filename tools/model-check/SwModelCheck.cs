// Read-only SolidWorks model checks for the MIRTE Master assembly.
// Compiled at run time by Check-Model.ps1 (Windows PowerShell 5.1, C# 5 -- keep syntax simple:
// no string interpolation, no ?. operator, no out var).
//
// Nothing in here saves or edits a document. The only exception is the optional strict mode,
// which runs a forced rebuild in memory; the document is then marked as modified and must be
// closed without saving (Check-Model.ps1 says so in its report).

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using SolidWorks.Interop.sldworks;
using SolidWorks.Interop.swconst;

namespace MirteModelCheck
{
    public class Finding
    {
        public string Severity;   // "error" | "warning" | "info"
        public string Check;      // short id, e.g. "mate-error"
        public string Document;   // file name of the document the finding belongs to
        public string Item;       // feature / component name
        public string Message;

        public Finding(string severity, string check, string document, string item, string message)
        {
            Severity = severity; Check = check; Document = document; Item = item; Message = message;
        }
    }

    public class CheckOptions
    {
        public string AssemblyPath;
        public string[] ExpectedComponents = new string[0];
        public string[] AllowedSuppressedMates = new string[0];      // "file.SLDASM:MateName"
        public string[] AllowedSuppressedComponents = new string[0]; // full component path, e.g. "arm-1/Foo-1"
        public string[] AllowedUnmatedComponents = new string[0];    // "file.SLDASM:ComponentName"
        // Angle mates that define the reference ("upright") pose: "file.SLDASM:MateName".
        // They must be suppressed (so the arm can move) and the parts must still be in the pose they force.
        public string[] PoseMates = new string[0];
        public double PoseToleranceDeg = 0.1;
        // If 'Update component names when documents are replaced' is on: temporarily turn it off, close and reopen the
        // assembly so the saved instance names load, and turn it back on afterwards.
        public bool FixNameOption = true;
        public bool Strict;
    }

    public class CheckResult
    {
        public List<Finding> Findings = new List<Finding>();
        public List<string> Files = new List<string>();   // every CAD file the assembly uses (full paths)
        public string SolidWorksRevision;
        public string AssemblyTitle;
        public bool StrictRebuildDone;
        public bool NameOptionChanged;   // the check turned the option off; Run() turns it back on
        public HashSet<string> PoseMatesFound = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    }

    public static class Checker
    {
        static ISldWorks Connect()
        {
            object o;
            try { o = Marshal.GetActiveObject("SldWorks.Application"); }
            catch (COMException) { return null; }
            return (ISldWorks)o;
        }

        static string FileOf(ModelDoc2 d) { return Path.GetFileName(d.GetPathName()); }

        static bool Contains(string[] list, string value)
        {
            if (list == null) return false;
            foreach (string s in list) if (string.Equals(s, value, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        // Tools > Options > System Options > External References > 'Update component names when documents are replaced'.
        // With it on (the SolidWorks default), SolidWorks shows file-based component names instead of the saved instance
        // names (e.g. "Mecanum Wheel (dia 100) right-7" instead of "front_left_wheel-7"), so URDF names would change.
        const int NameOptionId = (int)swUserPreferenceToggle_e.swExtRefUpdateCompNames;

        public static CheckResult Run(CheckOptions opt)
        {
            var r = new CheckResult();
            ISldWorks sw = Connect();
            if (sw == null)
            {
                r.Findings.Add(new Finding("error", "solidworks-not-running", "", "", "SolidWorks is not running. Start SolidWorks and run the check again."));
                return r;
            }
            r.SolidWorksRevision = sw.RevisionNumber();
            try
            {
                RunChecks(sw, opt, r);
            }
            finally
            {
                // Always put the user's setting back, even if a check failed.
                if (r.NameOptionChanged) sw.SetUserPreferenceToggle(NameOptionId, true);
            }
            return r;
        }

        static void RunChecks(ISldWorks sw, CheckOptions opt, CheckResult r)
        {

            // Open the assembly, or attach to it if it is already open. Refuse a same-named copy from another folder.
            string full = Path.GetFullPath(opt.AssemblyPath);
            ModelDoc2 top = null;
            object[] open = (object[])sw.GetDocuments();
            if (open != null)
                foreach (ModelDoc2 d in open)
                {
                    if (string.Equals(d.GetTitle().Replace(".SLDASM", ""), Path.GetFileNameWithoutExtension(full), StringComparison.OrdinalIgnoreCase)
                        && !string.Equals(Path.GetFullPath(d.GetPathName()), full, StringComparison.OrdinalIgnoreCase))
                    {
                        r.Findings.Add(new Finding("error", "wrong-document-open", d.GetTitle(), "",
                            "A document with the same name is open from another folder: " + d.GetPathName() + ". Close it first."));
                        return;
                    }
                    if (string.Equals(Path.GetFullPath(d.GetPathName()), full, StringComparison.OrdinalIgnoreCase)) top = d;
                }

            if (sw.GetUserPreferenceToggle(NameOptionId))
            {
                if (!opt.FixNameOption)
                {
                    r.Findings.Add(new Finding("error", "update-component-names-on", "", "",
                        "Tools > Options > System Options > External References > 'Update component names when documents are replaced' is ON. " +
                        "SolidWorks then shows file-based component names instead of the saved instance names, so the URDF names change. " +
                        "Turn it off, close and reopen the assembly, and run the check again."));
                }
                else if (!ReloadWithSavedNames(sw, full, r))
                {
                    return;
                }
                else
                {
                    top = null;   // closed by ReloadWithSavedNames; reopened below
                }
            }

            if (top == null)
            {
                int err = 0, warn = 0;
                top = (ModelDoc2)sw.OpenDoc6(full, (int)swDocumentTypes_e.swDocASSEMBLY, (int)swOpenDocOptions_e.swOpenDocOptions_Silent, "", ref err, ref warn);
                if (top == null)
                {
                    r.Findings.Add(new Finding("error", "open-failed", Path.GetFileName(full), "", "Could not open the assembly (error code " + err + ")."));
                    return;
                }
            }
            r.AssemblyTitle = top.GetTitle();
            var topAsm = (AssemblyDoc)top;

            // Collect every document the assembly uses, and check components on the way.
            var docs = new List<ModelDoc2>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            docs.Add(top); seen.Add(top.GetPathName());
            var allNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            object[] comps = (object[])topAsm.GetComponents(false);
            if (comps != null)
                foreach (Component2 c in comps)
                {
                    allNames.Add(c.Name2);
                    string path = c.GetPathName();
                    if (c.IsSuppressed())
                    {
                        if (!Contains(opt.AllowedSuppressedComponents, c.Name2))
                            r.Findings.Add(new Finding("warning", "component-suppressed", FileOf(top), c.Name2, "Component is suppressed."));
                        continue;
                    }
                    if (string.IsNullOrEmpty(path) || !File.Exists(path))
                    {
                        r.Findings.Add(new Finding("error", "component-file-missing", FileOf(top), c.Name2, "Referenced file not found: " + path));
                        continue;
                    }
                    int supp = c.GetSuppression2();
                    if (supp == (int)swComponentSuppressionState_e.swComponentLightweight || supp == (int)swComponentSuppressionState_e.swComponentFullyLightweight)
                        r.Findings.Add(new Finding("warning", "component-lightweight", FileOf(top), c.Name2, "Component is lightweight; its features are not checked. Resolve it to check it."));
                    ModelDoc2 md = (ModelDoc2)c.GetModelDoc2();
                    if (md == null)
                    {
                        if (supp != (int)swComponentSuppressionState_e.swComponentLightweight && supp != (int)swComponentSuppressionState_e.swComponentFullyLightweight)
                            r.Findings.Add(new Finding("error", "component-not-loaded", FileOf(top), c.Name2, "Component document is not loaded: " + path));
                        continue;
                    }
                    if (seen.Add(md.GetPathName())) docs.Add(md);
                }
            foreach (ModelDoc2 d in docs) r.Files.Add(d.GetPathName());

            // Expected components (the names the URDF export depends on).
            foreach (string e in opt.ExpectedComponents)
                if (!allNames.Contains(e))
                    r.Findings.Add(new Finding("error", "expected-component-missing", FileOf(top), e,
                        "Expected component not found. It was probably renamed, deleted or replaced; the URDF names depend on it."));

            // Unsaved changes and pending rebuilds -- the export must match the files on disk.
            foreach (ModelDoc2 d in docs)
            {
                if (d.GetSaveFlag())
                    r.Findings.Add(new Finding("error", "unsaved-changes", FileOf(d), "", "Document has unsaved changes. Save (or close without saving) before exporting."));
                if (d.Extension.NeedsRebuild2 != (int)swModelRebuildStatus_e.swModelRebuildStatus_FullyRebuilt)
                    r.Findings.Add(new Finding("error", "needs-rebuild", FileOf(d), "", "Document needs a rebuild (Ctrl+B), then save."));
            }

            CheckDocuments(docs, opt, r, "");

            foreach (string p in opt.PoseMates)
                if (!r.PoseMatesFound.Contains(p))
                    r.Findings.Add(new Finding("error", "pose-mate-missing", p.Split(':')[0], p.Contains(":") ? p.Split(':')[1] : p,
                        "Pose mate not found. It defines the upright reference pose of the arm; was it renamed or deleted?"));

            if (opt.Strict)
            {
                top.ForceRebuild3(false);
                r.StrictRebuildDone = true;
                var strictResult = new CheckResult();
                CheckDocuments(docs, opt, strictResult, " (after forced rebuild)");
                foreach (Finding f in strictResult.Findings)
                {
                    bool dup = false;
                    foreach (Finding g in r.Findings)
                        if (g.Check == f.Check && g.Document == f.Document && g.Item == f.Item) { dup = true; break; }
                    if (!dup) { f.Message += " Only appears after a forced rebuild."; r.Findings.Add(f); }
                }
            }
        }

        // The name option is on: turn it off, then close every open document from the assembly's folder (tree) and let the
        // caller reopen the assembly, so SolidWorks loads the saved instance names. Refuses (and changes nothing) if any
        // of those documents has unsaved changes. Returns false if the check cannot continue.
        static bool ReloadWithSavedNames(ISldWorks sw, string assemblyPath, CheckResult r)
        {
            string folder = Path.GetDirectoryName(assemblyPath).TrimEnd('\\') + "\\";
            var ours = new List<ModelDoc2>();
            var dirty = new List<string>();
            object[] docsNow = (object[])sw.GetDocuments();
            if (docsNow != null)
                foreach (ModelDoc2 d in docsNow)
                {
                    string p = d.GetPathName();
                    if (string.IsNullOrEmpty(p) || !p.StartsWith(folder, StringComparison.OrdinalIgnoreCase)) continue;
                    ours.Add(d);
                    if (d.GetSaveFlag()) dirty.Add(Path.GetFileName(p));
                }
            if (dirty.Count > 0)
            {
                r.Findings.Add(new Finding("error", "unsaved-changes", string.Join(", ", dirty.ToArray()), "",
                    "'Update component names when documents are replaced' is ON, so the check has to close and reopen the assembly " +
                    "to load the saved component names, but these documents have unsaved changes. Save them (or close them without saving) " +
                    "and run the check again. Nothing was changed."));
                return false;
            }

            sw.SetUserPreferenceToggle(NameOptionId, false);
            r.NameOptionChanged = true;

            // Close the top assembly first (its references go with it), then anything else from the folder still open.
            ModelDoc2 topDoc = null;
            foreach (ModelDoc2 d in ours)
                if (string.Equals(Path.GetFullPath(d.GetPathName()), assemblyPath, StringComparison.OrdinalIgnoreCase)) topDoc = d;
            if (topDoc != null) sw.CloseDoc(topDoc.GetPathName());
            for (int pass = 0; pass < 2; pass++)
            {
                docsNow = (object[])sw.GetDocuments();
                if (docsNow == null) break;
                foreach (ModelDoc2 d in docsNow)
                {
                    string p = d.GetPathName();
                    if (string.IsNullOrEmpty(p) || !p.StartsWith(folder, StringComparison.OrdinalIgnoreCase)) continue;
                    sw.CloseDoc(pass == 0 ? p : d.GetTitle());
                }
            }

            var stillOpen = new List<string>();
            docsNow = (object[])sw.GetDocuments();
            if (docsNow != null)
                foreach (ModelDoc2 d in docsNow)
                {
                    string p = d.GetPathName();
                    if (!string.IsNullOrEmpty(p) && p.StartsWith(folder, StringComparison.OrdinalIgnoreCase)) stillOpen.Add(Path.GetFileName(p));
                }
            if (stillOpen.Count > 0)
            {
                r.Findings.Add(new Finding("error", "reload-failed", string.Join(", ", stillOpen.ToArray()), "",
                    "Could not close these documents to reload the saved component names. Close them in SolidWorks and run the check again."));
                return false;
            }

            r.Findings.Add(new Finding("info", "component-name-option-overridden", "", "",
                "'Update component names when documents are replaced' was ON. The check turned it off, closed and reopened the assembly " +
                "so the saved component names load, and turned it back on afterwards. Keep the option off to skip this step."));
            return true;
        }

        static void CheckDocuments(List<ModelDoc2> docs, CheckOptions opt, CheckResult r, string suffix)
        {
            foreach (ModelDoc2 d in docs)
            {
                WhatsWrong(d, r, suffix);
                if (d.GetType() == (int)swDocumentTypes_e.swDocASSEMBLY)
                {
                    Mates(d, opt, r, suffix);
                    ComponentConstraints(d, opt, r, suffix);
                }
            }
        }

        // SolidWorks' own "What's Wrong" list: rebuild errors and warnings of features (and mates) in any document.
        static void WhatsWrong(ModelDoc2 d, CheckResult r, string suffix)
        {
            if (d.Extension.GetWhatsWrongCount() == 0) return;
            object feats, errs, warns;
            if (!d.Extension.GetWhatsWrong(out feats, out errs, out warns)) return;
            object[] f = (object[])feats; int[] e = (int[])errs; bool[] w = (bool[])warns;
            if (f == null) return;
            for (int i = 0; i < f.Length; i++)
            {
                Feature ft = f[i] as Feature;
                string name = ft != null ? ft.Name : "?";
                string code = Enum.GetName(typeof(swFeatureError_e), e[i]);
                if (code == null) code = e[i].ToString();
                bool isWarning = w != null && i < w.Length && w[i];
                r.Findings.Add(new Finding(isWarning ? "warning" : "error", isWarning ? "rebuild-warning" : "rebuild-error",
                    FileOf(d), name, "What's Wrong: " + code + suffix));
            }
        }

        // Mate errors, suppressed mates and misaligned mates, including mates in sub-folders.
        static void Mates(ModelDoc2 d, CheckOptions opt, CheckResult r, string suffix)
        {
            Feature f = (Feature)d.FirstFeature();
            while (f != null)
            {
                if (f.GetTypeName2() == "MateGroup") MateFolder(d, (Feature)f.GetFirstSubFeature(), opt, r, suffix);
                f = (Feature)f.GetNextFeature();
            }
        }

        static void MateFolder(ModelDoc2 d, Feature sf, CheckOptions opt, CheckResult r, string suffix)
        {
            while (sf != null)
            {
                string t = sf.GetTypeName2();
                if (t == "MisalignedMateFolder")
                {
                    var names = new List<string>();
                    Feature m = (Feature)sf.GetFirstSubFeature();
                    while (m != null) { names.Add(m.Name); m = (Feature)m.GetNextSubFeature(); }
                    r.Findings.Add(new Finding("warning", "mate-misaligned", FileOf(d), sf.Name,
                        "Misaligned mates" + (names.Count > 0 ? ": " + string.Join(", ", names.ToArray()) : "") + suffix));
                }
                else if (t == "FtrFolder" || t == "MateFeatureFolder")
                {
                    MateFolder(d, (Feature)sf.GetFirstSubFeature(), opt, r, suffix);
                }
                else if (Contains(opt.PoseMates, FileOf(d) + ":" + sf.Name))
                {
                    r.PoseMatesFound.Add(FileOf(d) + ":" + sf.Name);
                    PoseMate(d, sf, opt, r, suffix);
                }
                else
                {
                    bool warn;
                    int code = sf.GetErrorCode2(out warn);
                    if (sf.IsSuppressed())
                    {
                        if (!Contains(opt.AllowedSuppressedMates, FileOf(d) + ":" + sf.Name))
                            r.Findings.Add(new Finding("warning", "mate-suppressed", FileOf(d), sf.Name, "Mate is suppressed." + suffix));
                    }
                    else if (code != 0 || warn)
                    {
                        string name = Enum.GetName(typeof(swFeatureError_e), code);
                        if (name == null) name = code.ToString();
                        r.Findings.Add(new Finding(warn && code == 0 ? "warning" : "error", warn && code == 0 ? "mate-warning" : "mate-error",
                            FileOf(d), sf.Name, name + suffix));
                    }
                }
                sf = (Feature)sf.GetNextSubFeature();
            }
        }

        // A pose mate (angle mate between two planar faces) must be suppressed, and the current angle between its faces
        // must equal the angle the mate would enforce. Read-only: the mate is never unsuppressed.
        static void PoseMate(ModelDoc2 d, Feature sf, CheckOptions opt, CheckResult r, string suffix)
        {
            if (!sf.IsSuppressed())
                r.Findings.Add(new Finding("error", "pose-mate-active", FileOf(d), sf.Name,
                    "Pose mate is not suppressed, so the arm cannot move. Suppress it after putting the arm in its pose." + suffix));

            Mate2 m = sf.GetSpecificFeature2() as Mate2;
            if (m == null || m.Type != (int)swMateType_e.swMateANGLE || m.GetMateEntityCount() != 2)
            {
                r.Findings.Add(new Finding("error", "pose-mate-invalid", FileOf(d), sf.Name, "Pose mate is not an angle mate between two entities." + suffix));
                return;
            }

            // The angle the mate enforces (its dimension value), in degrees.
            double target;
            var def = sf.GetDefinition() as AngleMateFeatureData;
            if (def != null) target = def.Angle * 180.0 / Math.PI;
            else
            {
                DisplayDimension dd = (DisplayDimension)m.DisplayDimension2[0];
                if (dd == null) { r.Findings.Add(new Finding("error", "pose-mate-invalid", FileOf(d), sf.Name, "Cannot read the mate's angle." + suffix)); return; }
                target = ((Dimension)dd.GetDimension2(0)).SystemValue * 180.0 / Math.PI;
            }

            // Current angle between the two faces' normals (EntityParams: point xyz, then direction xyz).
            double[] a = (double[])m.MateEntity(0).EntityParams, b = (double[])m.MateEntity(1).EntityParams;
            if (a == null || b == null || a.Length < 6 || b.Length < 6)
            {
                r.Findings.Add(new Finding("warning", "pose-not-checked", FileOf(d), sf.Name, "Cannot read the mate's faces; pose not checked." + suffix));
                return;
            }
            double na = Math.Sqrt(a[3]*a[3]+a[4]*a[4]+a[5]*a[5]), nb = Math.Sqrt(b[3]*b[3]+b[4]*b[4]+b[5]*b[5]);
            if (na < 1e-12 || nb < 1e-12)
            {
                r.Findings.Add(new Finding("warning", "pose-not-checked", FileOf(d), sf.Name, "Mate faces have no direction; pose not checked." + suffix));
                return;
            }
            double dot = (a[3]*b[3]+a[4]*b[4]+a[5]*b[5]) / (na * nb);
            dot = Math.Max(-1.0, Math.Min(1.0, dot));
            double between = Math.Acos(dot) * 180.0 / Math.PI;   // 0..180

            // Aligned: normals at `target`; anti-aligned: at 180 - target; closest: whichever is nearer.
            double expAligned = Math.Abs(target), expAnti = 180.0 - Math.Abs(target);
            double expected;
            if (m.Alignment == (int)swMateAlign_e.swMateAlignALIGNED) expected = expAligned;
            else if (m.Alignment == (int)swMateAlign_e.swMateAlignANTI_ALIGNED) expected = expAnti;
            else expected = Math.Abs(between - expAligned) <= Math.Abs(between - expAnti) ? expAligned : expAnti;

            double dev = Math.Abs(between - expected);
            Component2 c0 = (Component2)m.MateEntity(0).ReferenceComponent, c1 = (Component2)m.MateEntity(1).ReferenceComponent;
            string pair = (c0 == null ? "?" : c0.Name2) + " / " + (c1 == null ? "?" : c1.Name2);
            if (dev > opt.PoseToleranceDeg)
                r.Findings.Add(new Finding("error", "arm-not-in-pose", FileOf(d), sf.Name, string.Format(
                    "{0} is {1:F2} deg away from the pose this mate defines (mate {2:F2} deg, faces now at {3:F2} deg, allowed {4:F2} deg). " +
                    "Unsuppress the pose mates, rebuild, suppress them again and save.{5}", pair, dev, target, between, opt.PoseToleranceDeg, suffix)));
            else
                r.Findings.Add(new Finding("info", "arm-in-pose", FileOf(d), sf.Name, string.Format(
                    "{0} in pose (deviation {1:F3} deg).{2}", pair, dev, suffix)));
        }

        // Over-constrained / unsolvable components, and components with no mates that are not fixed.
        static void ComponentConstraints(ModelDoc2 d, CheckOptions opt, CheckResult r, string suffix)
        {
            object[] comps = (object[])((AssemblyDoc)d).GetComponents(true);
            if (comps == null) return;
            foreach (Component2 c in comps)
            {
                if (c.IsSuppressed()) continue;
                int st = c.GetConstrainedStatus();
                if (st == (int)swConstrainedStatus_e.swOverConstrained || st == (int)swConstrainedStatus_e.swNoSolution || st == (int)swConstrainedStatus_e.swInvalidSolution)
                    r.Findings.Add(new Finding("error", "component-over-constrained", FileOf(d), c.Name2,
                        "Constraint status: " + Enum.GetName(typeof(swConstrainedStatus_e), st) + suffix));

                if (c.IsFixed() || c.IsPatternInstance() || c.IsMirrored()) continue;
                object[] mates = (object[])c.GetMates();
                if ((mates == null || mates.Length == 0) && !Contains(opt.AllowedUnmatedComponents, FileOf(d) + ":" + c.Name2))
                    r.Findings.Add(new Finding("error", "component-floating", FileOf(d), c.Name2, "Component has no mates and is not fixed." + suffix));
            }
        }
    }
}
