using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyProduct("BurnInLanPair")]
[assembly: AssemblyDescription("BurnInTest 網路配對工具")]
[assembly: AssemblyVersion("1.1.1.0")]
[assembly: AssemblyFileVersion("1.1.1.0")]
[assembly: AssemblyInformationalVersion("1.1.1")]
[assembly: AssemblyCompany("Tom24.Du")]

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool firstInstance;
        using (var session = new Mutex(true, @"Local\BurnInLanPair.UI", out firstInstance))
        {
            if (!firstInstance)
            {
                MessageBox.Show("已有一個 BurnInLanPair 視窗開啟。");
                return;
            }
            Application.Run(new MainForm());
        }
    }
}

internal sealed class MainForm : Form
{
    private readonly Button _btnSetup;
    private readonly Button _btnWrite;
    private readonly ProgressBar _progress;
    private readonly Label _status;
    private readonly string _exeDir;
    private readonly CheckBox _cpu = new CheckBox { Text = "CPU 100%", Checked = true, AutoSize = true, Location = new Point(24, 84) };
    private readonly CheckBox _memory = new CheckBox { Text = "MEM 100%", Checked = true, AutoSize = true, Location = new Point(220, 84) };
    private bool _busy;

    public MainForm()
    {
        string exePath = Assembly.GetExecutingAssembly().Location;
        _exeDir = Path.GetDirectoryName(exePath) ?? Environment.CurrentDirectory;

        Text = "BurnInLanPair v" + Application.ProductVersion;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = true;
        ClientSize = new Size(420, 260);
        Font = new Font("Segoe UI", 10f);

        _btnSetup = new Button
        {
            Text = "設定與配對",
            Location = new Point(24, 24),
            Size = new Size(170, 44)
        };
        _btnSetup.Click += (s, e) => StartAction("Setup");

        _btnWrite = new Button
        {
            Text = "寫入 BurnInTest",
            Location = new Point(220, 24),
            Size = new Size(176, 44)
        };
        _btnWrite.Click += (s, e) => StartAction("WriteBurnIn");

        _progress = new ProgressBar
        {
            Location = new Point(24, 128),
            Size = new Size(372, 28),
            Minimum = 0,
            Maximum = 100,
            Style = ProgressBarStyle.Continuous
        };

        _status = new Label
        {
            Text = "就緒",
            Location = new Point(24, 170),
            Size = new Size(372, 48),
            AutoEllipsis = true
        };

        Controls.AddRange(new Control[] { _cpu, _memory });
        Controls.Add(_btnSetup);
        Controls.Add(_btnWrite);
        Controls.Add(_progress);
        Controls.Add(_status);
        Controls.Add(new Label
        {
            Text = "作者：" + Application.CompanyName,
            Location = new Point(24, 222),
            Size = new Size(372, 28),
            Font = new Font(Font.FontFamily, 8f),
            TextAlign = ContentAlignment.MiddleRight
        });

        FormClosing += MainForm_FormClosing;
    }

    private void MainForm_FormClosing(object sender, FormClosingEventArgs e)
    {
        if (_busy)
        {
            e.Cancel = true;
            _status.Text = "正在執行，完成後即可關閉。";
        }
    }

    private static void ExtractScript(string scriptPath)
    {
        using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("BurnInLan.script"))
        {
            if (stream == null)
            {
                throw new InvalidOperationException("找不到內嵌的配對腳本。");
            }
            using (var reader = new StreamReader(stream, Encoding.UTF8))
            {
                File.WriteAllText(scriptPath, reader.ReadToEnd(), new UTF8Encoding(true));
            }
        }
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        _btnSetup.Enabled = !busy;
        _btnWrite.Enabled = !busy;
        _cpu.Enabled = _memory.Enabled = !busy;
        UseWaitCursor = busy;
    }

    private void SetProgress(int percent, string message)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action(() => SetProgress(percent, message)));
            return;
        }
        _progress.Value = Math.Max(0, Math.Min(100, percent));
        if (!string.IsNullOrWhiteSpace(message))
        {
            _status.Text = message;
        }
    }

    private void StartAction(string action)
    {
        if (_busy) return;
        SetBusy(true);
        SetProgress(0, action == "Setup" ? "設定與配對中…" : "寫入 BurnInTest 中…");

        string options = action == "WriteBurnIn"
            ? (_cpu.Checked ? "" : " -SkipCpu") + (_memory.Checked ? "" : " -SkipMemory")
            : "";
        ThreadPool.QueueUserWorkItem(_ => RunAction(action, options));
    }

    private void RunAction(string action, string options)
    {
        string scriptPath = Path.Combine(_exeDir, "BurnInLanPair-" + Guid.NewGuid().ToString("N") + ".ps1");
        var log = new StringBuilder();
        log.AppendLine(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        log.AppendLine("action=" + action);
        log.AppendLine("exeDir=" + _exeDir);

        string resultCode = null;
        string resultMessage = null;
        int exitCode = -1;

        try
        {
            ExtractScript(scriptPath);

            string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            var psi = new ProcessStartInfo
            {
                FileName = powershell,
                UseShellExecute = false,
                WorkingDirectory = _exeDir,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                CreateNoWindow = true
            };
            psi.EnvironmentVariables["BURNIN_LAN_HOME"] = _exeDir;
            psi.EnvironmentVariables["BURNIN_LAN_NO_PAUSE"] = "1";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\" -Action " + action + options;
            log.AppendLine("cmd=" + powershell + " " + psi.Arguments);

            WriteLog("burnin-lan-started.txt", log.ToString());

            var stdout = new StringBuilder();
            var stderr = new StringBuilder();
            using (Process process = Process.Start(psi))
            {
                AutoResetEvent outDone = new AutoResetEvent(false);
                AutoResetEvent errDone = new AutoResetEvent(false);
                process.OutputDataReceived += (s, e) =>
                {
                    if (e.Data == null) { outDone.Set(); return; }
                    stdout.AppendLine(e.Data);
                    HandleOutputLine(e.Data, ref resultCode, ref resultMessage);
                };
                process.ErrorDataReceived += (s, e) =>
                {
                    if (e.Data == null) { errDone.Set(); return; }
                    stderr.AppendLine(e.Data);
                };
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                process.WaitForExit();
                outDone.WaitOne(5000);
                errDone.WaitOne(5000);
                exitCode = process.ExitCode;
            }

            log.AppendLine("exit=" + exitCode);
            if (stdout.Length > 0)
            {
                log.AppendLine("--- stdout ---");
                log.AppendLine(stdout.ToString());
            }
            if (stderr.Length > 0)
            {
                log.AppendLine("--- stderr ---");
                log.AppendLine(stderr.ToString());
            }
            WriteLog("burnin-lan-last-run.txt", log.ToString());
            WriteLog("burnin-lan-last-" + action + ".txt", log.ToString());

            FinishAction(action, exitCode, resultCode, resultMessage, log.ToString());
        }
        catch (Exception ex)
        {
            log.AppendLine(ex.ToString());
            WriteLog("burnin-lan-error.txt", log.ToString());
            ShowDone(false, "啟動失敗", Truncate(ex.Message, 400));
        }
        finally
        {
            try { File.Delete(scriptPath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private void HandleOutputLine(string line, ref string resultCode, ref string resultMessage)
    {
        if (string.IsNullOrEmpty(line)) return;

        if (line.StartsWith("PROGRESS|", StringComparison.OrdinalIgnoreCase))
        {
            string[] parts = line.Split(new[] { '|' }, 3);
            int pct;
            if (parts.Length >= 2 && int.TryParse(parts[1], out pct))
            {
                string msg = parts.Length >= 3 ? parts[2] : null;
                SetProgress(pct, msg);
            }
            return;
        }

        if (line.StartsWith("RESULT|", StringComparison.OrdinalIgnoreCase))
        {
            string[] parts = line.Split(new[] { '|' }, 3);
            if (parts.Length >= 2) resultCode = parts[1];
            if (parts.Length >= 3) resultMessage = parts[2];
        }
    }

    private void FinishAction(string action, int exitCode, string resultCode, string resultMessage, string logText)
    {
        if (string.Equals(resultCode, "NO_STATE", StringComparison.OrdinalIgnoreCase) || exitCode == 3)
        {
            ShowDone(false, "尚未配對",
                string.IsNullOrWhiteSpace(resultMessage)
                    ? "請先按「設定與配對」。"
                    : resultMessage);
            return;
        }

        if (string.Equals(resultCode, "IP_ONLY", StringComparison.OrdinalIgnoreCase) || exitCode == 4)
        {
            ShowDone(false, "沒有配對結果",
                string.IsNullOrWhiteSpace(resultMessage)
                    ? "請接好網路線後再按「設定與配對」。"
                    : resultMessage);
            return;
        }

        if (exitCode == 0 && (string.Equals(resultCode, "OK", StringComparison.OrdinalIgnoreCase) || string.IsNullOrEmpty(resultCode)))
        {
            string title = action == "Setup" ? "設定完成" : "寫入完成";
            string body;
            if (action == "Setup")
            {
                string[] parts = (resultMessage ?? "").Split('|');
                string mode = parts[0];
                string pairCount = parts.Length > 1 ? parts[1] : "";
                if (string.Equals(mode, "Paired", StringComparison.OrdinalIgnoreCase))
                    body = "IP 已設定，找到 " + pairCount + " 條網路線。\n下一步：按「寫入 BurnInTest」。";
                else if (string.Equals(mode, "IpOnly", StringComparison.OrdinalIgnoreCase))
                    body = "IP 已設定，但沒有找到網路線。\n接好線後再按一次「設定與配對」。";
                else
                    body = string.IsNullOrWhiteSpace(resultMessage) ? "設定完成。" : resultMessage;
            }
            else
            {
                body = string.IsNullOrWhiteSpace(resultMessage)
                    ? "已寫入 BurnInTest。確認後按 GO 開始測試。"
                    : resultMessage;
            }
            ShowDone(true, title, body);
            return;
        }

        WriteLog("burnin-lan-error.txt", logText);
        ShowDone(false, "發生錯誤",
            Truncate(
                (string.IsNullOrWhiteSpace(resultMessage) ? "" : resultMessage + "\n\n") +
                "詳細紀錄：burnin-lan-error.txt",
                500));
    }

    private void ShowDone(bool ok, string title, string message)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action(() => ShowDone(ok, title, message)));
            return;
        }
        SetProgress(ok ? 100 : _progress.Value, title);
        SetBusy(false);
        MessageBox.Show(
            this,
            message,
            title,
            MessageBoxButtons.OK,
            ok ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
        if (ok) _status.Text = "就緒";
    }

    private void WriteLog(string fileName, string text)
    {
        try { File.WriteAllText(Path.Combine(_exeDir, fileName), text, new UTF8Encoding(true)); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static string Truncate(string value, int max)
    {
        if (string.IsNullOrEmpty(value)) return "(無訊息)";
        value = value.Trim();
        if (value.Length <= max) return value;
        return value.Substring(0, max) + "...";
    }
}
