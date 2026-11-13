using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

[assembly: AssemblyTitle("FTI PC Inventory Tool")]
[assembly: AssemblyDescription("Function International - Enterprise PC Hardware and Software Inventory Scanner")]
[assembly: AssemblyConfiguration("")]
[assembly: AssemblyCompany("Function International (FTI)")]
[assembly: AssemblyProduct("FTI PC Inventory Tool")]
[assembly: AssemblyCopyright("Copyright © Function International 2026")]
[assembly: AssemblyTrademark("FTI")]
[assembly: AssemblyCulture("")]
[assembly: AssemblyVersion("2026.11.10.1")]
[assembly: AssemblyFileVersion("2026.11.10.1")]
[assembly: AssemblyInformationalVersion("v2026.11.10.1 Enterprise (2026-11-10 21:43:56)")]

namespace FTI.PCInventory
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                string localAppDir = Path.Combine(localAppData, "FTI_PC_Inventory_Tool");

                string programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
                string engineDir = Path.Combine(programData, "FTI_PC_Inventory_Tool");

                EnsureSecureDirectory(engineDir);

                string scriptPath = Path.Combine(engineDir, "app_engine.ps1");

                // Extract embedded PowerShell engine
                using (Stream resStream = Assembly.GetExecutingAssembly().GetManifestResourceStream("FTI.Engine"))
                {
                    if (resStream != null)
                    {
                        using (FileStream fs = new FileStream(scriptPath, FileMode.Create, FileAccess.Write, FileShare.None))
                        {
                            resStream.CopyTo(fs);
                        }
                    }
                    else if (!File.Exists(scriptPath))
                    {
                        // Fallback for development if run directly from source folder
                        string currentDir = AppDomain.CurrentDomain.BaseDirectory;
                        string devScript = Path.Combine(currentDir, "src", "AppServer.ps1");
                        if (!File.Exists(devScript))
                        {
                            devScript = Path.Combine(currentDir, "AppServer.ps1");
                        }
                        if (File.Exists(devScript))
                        {
                            scriptPath = devScript;
                        }
                    }
                }

                // Identify host executable location
                string hostExe = null;
                try
                {
                    hostExe = Assembly.GetExecutingAssembly().Location;
                }
                catch { }
                if (string.IsNullOrEmpty(hostExe) || !File.Exists(hostExe))
                {
                    try
                    {
                        hostExe = Process.GetCurrentProcess().MainModule.FileName;
                    }
                    catch { }
                }

                // Prepare PowerShell launcher arguments
                StringBuilder argBuilder = new StringBuilder();
                argBuilder.Append("-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ");
                argBuilder.Append(EscapeProcessArgument(scriptPath));

                // Forward command line arguments
                if (args != null && args.Length > 0)
                {
                    foreach (string arg in args)
                    {
                        argBuilder.Append(" ").Append(EscapeProcessArgument(arg));
                    }
                }

                ProcessStartInfo psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = argBuilder.ToString(),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                if (!string.IsNullOrEmpty(hostExe) && File.Exists(hostExe))
                {
                    psi.EnvironmentVariables["FTI_HOST_EXE"] = hostExe;
                }

                using (Process proc = Process.Start(psi))
                {
                    if (proc != null)
                    {
                        bool isSilent = false;
                        if (args != null)
                        {
                            foreach (string a in args)
                            {
                                if (a.Equals("-Silent", StringComparison.OrdinalIgnoreCase) ||
                                    a.Equals("-ScheduledRun", StringComparison.OrdinalIgnoreCase))
                                {
                                    isSilent = true;
                                    break;
                                }
                            }
                        }

                        if (isSilent)
                        {
                            proc.WaitForExit();
                            RestoreLidActionFallback(localAppDir);
                            return proc.ExitCode;
                        }
                        else
                        {
                            // In interactive mode, wait for server process so launcher stays clean
                            proc.WaitForExit();
                            RestoreLidActionFallback(localAppDir);
                            return proc.ExitCode;
                        }
                    }
                }

                RestoreLidActionFallback(localAppDir);
                return 0;
            }
            catch (Exception ex)
            {
                try
                {
                    string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                    string localAppDir = Path.Combine(localAppData, "FTI_PC_Inventory_Tool");
                    RestoreLidActionFallback(localAppDir);
                    if (!Directory.Exists(localAppDir))
                    {
                        Directory.CreateDirectory(localAppDir);
                    }
                    string logFile = Path.Combine(localAppDir, "launcher_error.log");
                    File.AppendAllText(logFile, string.Format("[{0}] Launcher Exception: {1}\r\n", DateTime.Now, ex));
                }
                catch { }

                return 1;
            }
        }

        private static void EnsureSecureDirectory(string path)
        {
            DirectorySecurity dSecurity = new DirectorySecurity();
            dSecurity.SetAccessRuleProtection(true, false);

            SecurityIdentifier adminSid = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            SecurityIdentifier systemSid = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);

            FileSystemAccessRule adminRule = new FileSystemAccessRule(
                adminSid,
                FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None,
                AccessControlType.Allow);

            FileSystemAccessRule systemRule = new FileSystemAccessRule(
                systemSid,
                FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None,
                AccessControlType.Allow);

            dSecurity.AddAccessRule(adminRule);
            dSecurity.AddAccessRule(systemRule);

            if (!Directory.Exists(path))
            {
                Directory.CreateDirectory(path, dSecurity);
            }
            DirectoryInfo di = new DirectoryInfo(path);
            di.SetAccessControl(dSecurity);
        }

        private static string EscapeProcessArgument(string arg)
        {
            if (string.IsNullOrEmpty(arg))
            {
                return "\"\"";
            }

            bool needsQuotes = false;
            for (int i = 0; i < arg.Length; i++)
            {
                char c = arg[i];
                if (c == ' ' || c == '\t' || c == '"')
                {
                    needsQuotes = true;
                    break;
                }
            }

            if (!needsQuotes)
            {
                return arg;
            }

            StringBuilder sb = new StringBuilder();
            sb.Append('"');
            int backslashCount = 0;

            for (int i = 0; i < arg.Length; i++)
            {
                char c = arg[i];
                if (c == '\\')
                {
                    backslashCount++;
                }
                else if (c == '"')
                {
                    sb.Append(new string('\\', backslashCount * 2 + 1));
                    sb.Append('"');
                    backslashCount = 0;
                }
                else
                {
                    if (backslashCount > 0)
                    {
                        sb.Append(new string('\\', backslashCount));
                        backslashCount = 0;
                    }
                    sb.Append(c);
                }
            }

            if (backslashCount > 0)
            {
                sb.Append(new string('\\', backslashCount * 2));
            }
            sb.Append('"');

            return sb.ToString();
        }

        private static void RestoreLidActionFallback(string localAppDir)
        {
            try
            {
                if (string.IsNullOrEmpty(localAppDir))
                {
                    string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                    localAppDir = Path.Combine(localAppData, "FTI_PC_Inventory_Tool");
                }
                if (!Directory.Exists(localAppDir)) return;
                string backupFile = Path.Combine(localAppDir, "lid_power_backup.json");
                if (File.Exists(backupFile))
                {
                    string content = File.ReadAllText(backupFile);
                    int acVal = 1;
                    int dcVal = 1;
                    int pAc = content.IndexOf("\"ac\":");
                    if (pAc >= 0)
                    {
                        string s = content.Substring(pAc + 5).Trim();
                        int end = s.IndexOfAny(new char[] { ',', '}', '\r', '\n' });
                        if (end > 0) int.TryParse(s.Substring(0, end).Trim(), out acVal);
                    }
                    int pDc = content.IndexOf("\"dc\":");
                    if (pDc >= 0)
                    {
                        string s = content.Substring(pDc + 5).Trim();
                        int end = s.IndexOfAny(new char[] { ',', '}', '\r', '\n' });
                        if (end > 0) int.TryParse(s.Substring(0, end).Trim(), out dcVal);
                    }

                    ProcessStartInfo psi = new ProcessStartInfo("powercfg.exe")
                    {
                        CreateNoWindow = true,
                        UseShellExecute = false,
                        WindowStyle = ProcessWindowStyle.Hidden
                    };
                    psi.Arguments = string.Format("/setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION {0}", acVal);
                    using (Process p = Process.Start(psi)) { if (p != null) p.WaitForExit(1000); }
                    psi.Arguments = string.Format("/setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION {0}", dcVal);
                    using (Process p = Process.Start(psi)) { if (p != null) p.WaitForExit(1000); }
                    psi.Arguments = "/setactive SCHEME_CURRENT";
                    using (Process p = Process.Start(psi)) { if (p != null) p.WaitForExit(1000); }

                    File.Delete(backupFile);
                }
            }
            catch { }
        }
    }
}
