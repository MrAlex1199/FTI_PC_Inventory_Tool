using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

[assembly: AssemblyTitle("FTI PC Inventory Tool")]
[assembly: AssemblyDescription("Federation of Thai Industries - Enterprise PC Hardware and Software Inventory Scanner")]
[assembly: AssemblyConfiguration("")]
[assembly: AssemblyCompany("Federation of Thai Industries (FTI)")]
[assembly: AssemblyProduct("FTI PC Inventory Tool")]
[assembly: AssemblyCopyright("Copyright © Federation of Thai Industries 2026")]
[assembly: AssemblyTrademark("FTI")]
[assembly: AssemblyCulture("")]
[assembly: AssemblyVersion("2.5.0.0")]
[assembly: AssemblyFileVersion("2.5.0.0")]

namespace FTI.PCInventory
{
    internal static class Program
    {
        // Embedded script payload will be injected into this placeholder by build.ps1
        public static string ScriptPayload = "###SCRIPT_PAYLOAD_PLACEHOLDER###";

        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                string appDir = Path.Combine(localAppData, "FTI_PC_Inventory_Tool");
                if (!Directory.Exists(appDir))
                {
                    Directory.CreateDirectory(appDir);
                }

                string scriptPath = Path.Combine(appDir, "app_engine.ps1");

                // Decode payload and write script
                if (!string.IsNullOrEmpty(ScriptPayload) && ScriptPayload != "###SCRIPT_PAYLOAD_PLACEHOLDER###")
                {
                    byte[] scriptBytes = Convert.FromBase64String(ScriptPayload);
                    File.WriteAllBytes(scriptPath, scriptBytes);
                }
                else
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

                // Prepare PowerShell launcher arguments
                StringBuilder argBuilder = new StringBuilder();
                argBuilder.Append("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ");
                argBuilder.Append("\"").Append(scriptPath).Append("\"");

                // Forward command line arguments
                if (args != null && args.Length > 0)
                {
                    foreach (string arg in args)
                    {
                        argBuilder.Append(" ");
                        if (arg.Contains(" ") && !arg.StartsWith("\""))
                        {
                            argBuilder.Append("\"").Append(arg).Append("\"");
                        }
                        else
                        {
                            argBuilder.Append(arg);
                        }
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

                using (Process proc = Process.Start(psi))
                {
                    if (proc != null)
                    {
                        // Check if running in silent/scheduled mode
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
                            return proc.ExitCode;
                        }
                        else
                        {
                            // In interactive mode, wait briefly to ensure server launched properly
                            proc.WaitForExit();
                            return proc.ExitCode;
                        }
                    }
                }

                return 0;
            }
            catch (Exception ex)
            {
                // Write exception log in app directory
                try
                {
                    string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                    string logFile = Path.Combine(localAppData, "FTI_PC_Inventory_Tool", "launcher_error.log");
                    File.AppendAllText(logFile, string.Format("[{0}] Launcher Exception: {1}\r\n", DateTime.Now, ex));
                }
                catch { }

                return 1;
            }
        }
    }
}
