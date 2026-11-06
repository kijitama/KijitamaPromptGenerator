using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using System.Web.Script.Serialization;

[assembly: AssemblyTitle("Kijitama Prompt Generator")]
[assembly: AssemblyProduct("Kijitama Prompt Generator")]
[assembly: AssemblyVersion("0.1.0.0")]

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            bool smokeTest = args.Length == 1 && args[0] == "--smoke-test";
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = ReadScriptPath(root);
            string engine = FindPowerShell();
            if (engine == null)
                throw new FileNotFoundException("PowerShell 7が見つかりません。PowerShell 7をインストールしてから起動してください。");
            var info = new ProcessStartInfo
            {
                FileName = engine,
                Arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File \"" + script + "\"" + (smokeTest ? " -SmokeTest" : ""),
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (var child = Process.Start(info))
            {
                if (child == null) throw new InvalidOperationException("アプリを起動できませんでした。");
                if (smokeTest) { child.WaitForExit(); return child.ExitCode; }
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show("起動できませんでした。\n\n" + error.Message,
                "Kijitama Prompt Generator", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static string ReadScriptPath(string root)
    {
        string config = Path.Combine(root, "app", "Launcher", "launcher.json");
        if (!File.Exists(config)) throw new FileNotFoundException("起動設定が見つかりません。\n" + config);
        Dictionary<string, object> settings;
        try
        {
            settings = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(config));
        }
        catch (ArgumentException)
        {
            throw new InvalidDataException("launcher.json のJSON形式を確認してください。");
        }
        object value;
        if (settings == null || !settings.TryGetValue("script", out value) || !(value is string))
            throw new InvalidDataException("launcher.json の script に.ps1ファイルのパスを指定してください。");
        string script = Path.GetFullPath(Path.Combine(root, ((string)value).Trim()));
        if (!String.Equals(Path.GetExtension(script), ".ps1", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("launcher.json の script には.ps1ファイルを指定してください。");
        if (!File.Exists(script)) throw new FileNotFoundException("起動スクリプトが見つかりません。\n" + script);
        return script;
    }

    private static string FindPowerShell()
    {
        var candidates = new List<string>();
        foreach (string variable in new[] { "ProgramW6432", "ProgramFiles", "LOCALAPPDATA" })
        {
            string folder = Environment.GetEnvironmentVariable(variable);
            if (!String.IsNullOrEmpty(folder)) candidates.Add(Path.Combine(folder, "PowerShell", "7", "pwsh.exe"));
        }
        foreach (string folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            string clean = folder.Trim().Trim('"');
            if (!String.IsNullOrEmpty(clean) && Path.IsPathRooted(clean)) candidates.Add(Path.Combine(clean, "pwsh.exe"));
        }
        // Also support the existing Codex-bundled PowerShell runtime.
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".cache", "codex-runtimes", "codex-primary-runtime", "dependencies", "native", "powershell", "pwsh.exe"));
        foreach (string candidate in candidates)
        {
            // WindowsApps aliases can open a terminal. Use the actual executable.
            if (candidate.IndexOf("\\Microsoft\\WindowsApps\\", StringComparison.OrdinalIgnoreCase) >= 0) continue;
            if (File.Exists(candidate)) return Path.GetFullPath(candidate);
        }
        return null;
    }
}
