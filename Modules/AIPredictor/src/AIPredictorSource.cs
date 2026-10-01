// AIPredictorSource.cs —— AI 命令预测器（PowerShell 引擎子系统 ICommandPredictor 实现）
//
// 为什么用 C# 而不是纯 PowerShell：
//   PowerShell 类虽然能实现 ICommandPredictor，但方法返回值 SuggestionPackage 是结构体，
//   PS 类 -> CLR 接口的返回值封送会失败（实测引擎收到空包）。用 C# 实现则完全正常。
//
// 工作方式：
//   GetSuggestion 被 PSReadLine 高频调用，必须立刻返回 —— 所以它只查缓存，
//   未命中时把输入交给后台线程去请求大模型，下一次按键就能看到建议。
//   另有 Query 方法供快捷键同步调用。

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Management.Automation;
using System.Management.Automation.Subsystem;
using System.Management.Automation.Subsystem.Prediction;

namespace AIPredictor
{
    /// <summary>预测器配置（由 AIPredictor.psm1 从 config.json 填充）</summary>
    public sealed class AIPredictorOptions
    {
        public string ApiKey { get; set; } = string.Empty;
        public string Model { get; set; } = "qwen3-max";
        public string Endpoint { get; set; } = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions";
        public int TimeoutSeconds { get; set; } = 8;
        public int MinInputLength { get; set; } = 4;
        public int DebounceMs { get; set; } = 800;
        public int MaxTokens { get; set; } = 200;
        public double Temperature { get; set; } = 0.2;
        public int MaxCacheEntries { get; set; } = 200;
        public int MaxSuggestionLength { get; set; } = 500;
        public bool EnableLog { get; set; } = false;
        public string LogPath { get; set; } = string.Empty;
        public string SystemPrompt { get; set; } = string.Empty;
    }

    public sealed class AIPredictorSource : ICommandPredictor
    {
        // 固定 Id：注册/注销时用它定位本预测器
        private static readonly Guid PredictorId = new Guid("6c1f0f9a-3f6b-4c1e-9d2a-5b7c8e0f1a2b");
        private static readonly object LogLock = new object();

        private readonly AIPredictorOptions _options;
        private readonly HttpClient _client;
        private readonly ConcurrentDictionary<string, string> _cache =
            new ConcurrentDictionary<string, string>(StringComparer.Ordinal);

        private string _pending;              // 最新等待请求的输入（尾沿防抖）
        private int _busy;                    // 0/1：是否有请求在飞
        private DateTime _lastRequestUtc = DateTime.MinValue;

        public AIPredictorSource(AIPredictorOptions options)
        {
            _options = options ?? new AIPredictorOptions();
            _client = new HttpClient { Timeout = TimeSpan.FromSeconds(Math.Max(2, _options.TimeoutSeconds)) };
            if (!string.IsNullOrWhiteSpace(_options.ApiKey))
            {
                _client.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", "Bearer " + _options.ApiKey);
            }
        }

        // ---------------- ICommandPredictor ----------------

        public Guid Id => PredictorId;
        public string Name => "AIPredictor";
        public string Description => "AI 命令预测（" + _options.Model + "）";
        public Dictionary<string, string> FunctionsToDefine => new Dictionary<string, string>();

        /// <summary>PSReadLine 每次按键都会调用，必须立刻返回：只查缓存，未命中就丢给后台线程。</summary>
        public SuggestionPackage GetSuggestion(PredictionClient client, PredictionContext context, CancellationToken token)
        {
            try
            {
                string line = GetInputLine(context);
                string suggestion = Lookup(line);
                var entries = new List<PredictiveSuggestion>();
                if (!string.IsNullOrEmpty(suggestion))
                {
                    entries.Add(new PredictiveSuggestion(suggestion, "AI · " + _options.Model + "（Enter 执行，Tab 菜单另可选）"));
                }
                return new SuggestionPackage(entries);
            }
            catch (Exception ex)
            {
                LastError = ex.Message;
                return new SuggestionPackage(new List<PredictiveSuggestion>());
            }
        }

        public bool CanAcceptFeedback(PredictionClient client, PredictorFeedbackKind feedback)
        {
            return feedback == PredictorFeedbackKind.SuggestionAccepted;
        }

        public void OnSuggestionAccepted(PredictionClient client, uint session, string acceptedSuggestion)
        {
            Log("已采纳: " + acceptedSuggestion);
        }

        public void OnSuggestionDisplayed(PredictionClient client, uint session, int countOrLength) { }
        public void OnCommandLineAccepted(PredictionClient client, IReadOnlyList<string> history) { }
        public void OnCommandLineExecuted(PredictionClient client, string commandLine, bool success) { }

        // ---------------- 对外（PowerShell 调用）----------------

        public string LastError { get; private set; } = string.Empty;
        public int CacheCount => _cache.Count;
        public bool HasApiKey => !string.IsNullOrWhiteSpace(_options.ApiKey);

        /// <summary>查缓存；未命中则安排后台请求并返回 null。</summary>
        public string Lookup(string line)
        {
            if (!IsEligible(line)) return null;
            line = line.Trim();

            string cached;
            if (_cache.TryGetValue(line, out cached)) return cached;

            _pending = line;
            PumpRequests();
            return null;
        }

        /// <summary>同步查询（快捷键用）：最多等 timeoutMs 毫秒。</summary>
        public string Query(string line, int timeoutMs)
        {
            if (!IsEligible(line)) return null;
            line = line.Trim();

            string cached;
            if (_cache.TryGetValue(line, out cached)) return cached;

            try
            {
                Task<string> task = FetchAsync(line);
                if (task.Wait(Math.Max(1000, timeoutMs)) && !string.IsNullOrEmpty(task.Result))
                {
                    Store(line, task.Result);
                    return task.Result;
                }
                LastError = "请求超时或返回为空（" + Math.Max(1000, timeoutMs) + " ms）";
            }
            catch (Exception ex)
            {
                LastError = ex.Message;
                Log("同步查询失败: " + ex.Message);
            }
            return null;
        }

        // ---------------- 内部实现 ----------------

        /// <summary>尾沿防抖：同时在飞最多一个请求，请求完成后自动补发最新输入。</summary>
        private void PumpRequests()
        {
            if (Interlocked.CompareExchange(ref _busy, 1, 0) != 0) return;

            string line = Interlocked.Exchange(ref _pending, null);
            if (string.IsNullOrEmpty(line))
            {
                Volatile.Write(ref _busy, 0);
                return;
            }

            double waitMs = _options.DebounceMs - (DateTime.UtcNow - _lastRequestUtc).TotalMilliseconds;
            Task.Run(async () =>
            {
                try
                {
                    if (waitMs > 0) await Task.Delay((int)waitMs).ConfigureAwait(false);
                    _lastRequestUtc = DateTime.UtcNow;
                    string result = await FetchAsync(line).ConfigureAwait(false);
                    if (!string.IsNullOrEmpty(result)) Store(line, result);
                }
                catch (Exception ex)
                {
                    LastError = ex.Message;
                    Log("后台请求失败: " + ex.Message);
                }
                finally
                {
                    Volatile.Write(ref _busy, 0);
                    PumpRequests();   // 处理等待期间新出现的输入
                }
            });
        }

        private bool IsEligible(string line)
        {
            if (string.IsNullOrWhiteSpace(line)) return false;
            if (!HasApiKey) return false;
            line = line.Trim();
            if (line.Length < _options.MinInputLength) return false;
            // 纯 cmdlet / 参数（英文数字连字符）不打扰 AI，正常打字不触发请求
            if (Regex.IsMatch(line, "^[a-zA-Z][a-zA-Z0-9-]*$")) return false;
            return true;
        }

        private static string GetInputLine(PredictionContext context)
        {
            try
            {
                if (context == null || context.InputAst == null || context.InputAst.Extent == null) return string.Empty;
                return (context.InputAst.Extent.Text ?? string.Empty).Trim();
            }
            catch { return string.Empty; }
        }

        private async Task<string> FetchAsync(string line)
        {
            if (!HasApiKey) { LastError = "未配置 ApiKey"; return null; }

            var messages = new List<object>
            {
                new { role = "system", content = BuildSystemPrompt() },
                new { role = "user", content = line }
            };
            var payload = new
            {
                model = _options.Model,
                messages = messages,
                temperature = _options.Temperature,
                max_tokens = _options.MaxTokens,
                stream = false
            };

            string json = JsonSerializer.Serialize(payload);
            using (var content = new StringContent(json, Encoding.UTF8, "application/json"))
            using (HttpResponseMessage response = await _client.PostAsync(_options.Endpoint, content).ConfigureAwait(false))
            {
                string body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                {
                    LastError = "HTTP " + (int)response.StatusCode + ": " + Shorten(body, 200);
                    Log("HTTP 错误: " + LastError);
                    return null;
                }

                using (JsonDocument document = JsonDocument.Parse(body))
                {
                    JsonElement root = document.RootElement;
                    JsonElement choices;
                    if (!root.TryGetProperty("choices", out choices) ||
                        choices.ValueKind != JsonValueKind.Array || choices.GetArrayLength() == 0)
                    {
                        LastError = "响应中没有 choices";
                        return null;
                    }

                    JsonElement message;
                    JsonElement contentElement;
                    if (!choices[0].TryGetProperty("message", out message) ||
                        !message.TryGetProperty("content", out contentElement))
                    {
                        LastError = "响应结构不认识";
                        return null;
                    }

                    return Sanitize(contentElement.GetString(), _options.MaxSuggestionLength);
                }
            }
        }

        private string BuildSystemPrompt()
        {
            if (!string.IsNullOrWhiteSpace(_options.SystemPrompt)) return _options.SystemPrompt;

            return "你是 PowerShell 命令助手。用户用自然语言描述需求，你输出一条可直接执行的 PowerShell 命令。" +
                   "硬性要求：只输出命令本身（单行），不要解释、不要 Markdown 代码块、不要用引号把整条命令包起来；" +
                   "优先使用现代 cmdlet；除非用户明确要求，不要使用 Remove-Item -Recurse -Force、Format-Volume、Invoke-Expression 等危险操作。" +
                   "环境：Windows；PowerShell " + Shorten(typeof(PSObject).Assembly.GetName().Version.ToString(), 20) +
                   "；当前目录 " + SafeCurrentDirectory() + "。";
        }

        private static string SafeCurrentDirectory()
        {
            try { return Environment.CurrentDirectory; } catch { return "?"; }
        }

        private void Store(string line, string suggestion)
        {
            if (_cache.Count >= _options.MaxCacheEntries) _cache.Clear();
            _cache[line] = suggestion;
            LastError = string.Empty;
            Log("预测: " + line + "  =>  " + suggestion);
        }

        private void Log(string message)
        {
            if (!_options.EnableLog || string.IsNullOrWhiteSpace(_options.LogPath)) return;
            try
            {
                lock (LogLock)
                {
                    File.AppendAllText(_options.LogPath,
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine,
                        new UTF8Encoding(false));
                }
            }
            catch { }
        }

        // ---------------- 文本清洗 ----------------

        /// <summary>把模型输出整成一条可以直接放进命令行的命令。</summary>
        public static string Sanitize(string raw, int maxLength)
        {
            if (string.IsNullOrWhiteSpace(raw)) return null;

            string text = raw.Replace("\r\n", "\n").Replace('\r', '\n').Trim();

            if (text.StartsWith("```", StringComparison.Ordinal))
            {
                int newline = text.IndexOf('\n');
                if (newline >= 0) text = text.Substring(newline + 1);
                int end = text.LastIndexOf("```", StringComparison.Ordinal);
                if (end >= 0) text = text.Substring(0, end);
            }

            // 逐行打分：说明文字（以冒号结尾等）会被跳过，优先挑出真正像命令的那一行
            string best = null;
            int bestScore = int.MinValue;
            foreach (string rawLine in text.Split('\n'))
            {
                string candidate = rawLine.Trim().Trim('`').Trim();
                if (candidate.Length == 0) continue;

                // 去掉 "PS C:\>" 之类的前缀
                int promptEnd = candidate.IndexOf('>');
                if (promptEnd > 0 && candidate.StartsWith("PS ", StringComparison.OrdinalIgnoreCase))
                {
                    candidate = candidate.Substring(promptEnd + 1).Trim();
                }

                candidate = TrimWrappingQuotes(candidate);
                if (candidate.Length == 0) continue;

                int score = ScoreLine(candidate);
                if (score > bestScore)
                {
                    bestScore = score;
                    best = candidate;
                    if (score >= 6) break;   // 已经是明显的 cmdlet，不用再挑
                }
            }

            if (best == null) return null;
            if (best.Length > maxLength) best = best.Substring(0, maxLength).TrimEnd();
            return best.Length == 0 ? null : best;
        }

        /// <summary>给一行文本打分：越像 PowerShell 命令分越高，纯说明文字得负分。</summary>
        private static int ScoreLine(string line)
        {
            int score = 0;
            if (line.EndsWith(":") || line.EndsWith("：")) score -= 5;
            if (Regex.IsMatch(line, @"^[A-Za-z][A-Za-z0-9]*(-[A-Za-z][A-Za-z0-9]*)+")) score += 6;   // Get-ChildItem
            if (line.IndexOf('|') >= 0) score += 3;
            if (line.StartsWith("$")) score += 3;
            if (line.StartsWith("&") || line.StartsWith(".")) score += 2;
            if (Regex.IsMatch(line, @"^[A-Za-z][A-Za-z0-9]*\s+-[A-Za-z]")) score += 3;              // ping -n 3
            if (Regex.IsMatch(line, @"^[A-Za-z]:\\")) score += 2;                                  // 路径
            return score;
        }

        private static string TrimWrappingQuotes(string value)
        {
            if (value.Length < 2) return value;
            char first = value[0];
            if ((first == '"' || first == '\'') && value[value.Length - 1] == first)
            {
                int count = 0;
                foreach (char c in value) { if (c == first) count++; }
                if (count == 2) return value.Substring(1, value.Length - 2).Trim();
            }
            return value;
        }

        private static string Shorten(string value, int max)
        {
            if (string.IsNullOrEmpty(value)) return string.Empty;
            value = value.Replace("\n", " ").Replace("\r", " ").Trim();
            return value.Length <= max ? value : value.Substring(0, max) + "…";
        }
    }
}