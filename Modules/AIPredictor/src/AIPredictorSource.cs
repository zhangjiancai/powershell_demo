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
        public int CacheTtlSeconds { get; set; } = 600;
        public bool AllowMultiLine { get; set; } = true;
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
        private readonly ConcurrentDictionary<string, CacheEntry> _cache =
            new ConcurrentDictionary<string, CacheEntry>(StringComparer.Ordinal);

        // 同一行同时最多一个在途请求（Tab/Alt+P 连按不会重复打 API）
        private readonly ConcurrentDictionary<string, Task<string>> _inflight =
            new ConcurrentDictionary<string, Task<string>>(StringComparer.Ordinal);

        // 中日韩文字：出现即按自然语言处理
        private static readonly Regex CjkPattern = new Regex(
            "[\\u3040-\\u30ff\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff\\uac00-\\ud7af]",
            RegexOptions.Compiled);

        private sealed class CacheEntry
        {
            public string Text;
            public DateTime Utc;
        }

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
                bool multiLine = !string.IsNullOrEmpty(suggestion) && suggestion.IndexOf('\n') >= 0;
                string state = string.IsNullOrEmpty(suggestion)
                    ? "(无缓存，已排后台请求)"
                    : (multiLine ? "命中缓存（多行脚本，行内不显示）" : "命中缓存");
                Log("GetSuggestion: \"" + Shorten(line, 60) + "\" -> " + state);
                var entries = new List<PredictiveSuggestion>();
                if (!string.IsNullOrEmpty(suggestion) && !multiLine)
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

            string cached = GetCached(line);
            if (cached != null) return cached;

            _pending = line;
            PumpRequests();
            return null;
        }

        /// <summary>同步查询（快捷键用）：最多等 timeoutMs 毫秒。</summary>
        public string Query(string line, int timeoutMs)
        {
            if (!IsEligible(line)) return null;
            line = line.Trim();

            string cached = GetCached(line);
            if (cached != null) return cached;

            int wait = Math.Max(1000, timeoutMs);
            try
            {
                Task<string> task = GetOrStartFetch(line);
                if (task.Wait(wait))
                {
                    string result = task.Result;
                    if (!string.IsNullOrEmpty(result)) return result;
                    LastError = "模型没有给出可用的命令（可能只返回了说明文字或多行脚本）";
                }
                else
                {
                    LastError = "请求超时（" + wait + " ms），结果到了会进缓存，可稍后再按一次";
                }
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

            Log("发起请求: \"" + Shorten(line, 60) + "\"");
            double waitMs = _options.DebounceMs - (DateTime.UtcNow - _lastRequestUtc).TotalMilliseconds;
            Task.Run(async () =>
            {
                try
                {
                    if (waitMs > 0) await Task.Delay((int)waitMs).ConfigureAwait(false);
                    _lastRequestUtc = DateTime.UtcNow;
                    await GetOrStartFetch(line).ConfigureAwait(false);   // 结果由 GetOrStartFetch 统一写缓存
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
            return IsNaturalLanguage(line);
        }

        /// <summary>
        /// 判断输入是不是“自然语言需求”，而不是在编辑命令。
        /// PowerShell 侧的 Tab 接管调用同一个方法，保证两边判断一致。
        /// </summary>
        public static bool IsNaturalLanguage(string line)
        {
            if (string.IsNullOrWhiteSpace(line)) return false;
            line = line.Trim();

            // 1) 开头就是命令形态 → 不是自然语言
            if (line.StartsWith("./") || line.StartsWith(".\\") || line.StartsWith("/") ||
                line.StartsWith("\\") || line.StartsWith("$") || line.StartsWith("&") ||
                line.StartsWith("@") || line.StartsWith("\"") || line.StartsWith("'") ||
                line.StartsWith("-")) return false;
            if (Regex.IsMatch(line, @"^[A-Za-z]:[\\/]?")) return false;                                  // 盘符
            if (Regex.IsMatch(line, @"^[A-Za-z][A-Za-z0-9]*(-[A-Za-z][A-Za-z0-9]*)+")) return false;     // cmdlet
            if (Regex.IsMatch(line, @"(?i)^(adb|git|npm|pnpm|yarn|pip|pip3|docker|winget|dotnet|node|python|python3|kubectl|curl|ssh|scp|choco|scoop|go|cargo|java|javac|mvn|gradle|az|gh|aws|terraform|pwsh|powershell|cmd|bash|wsl|reg|sc|netsh|ipconfig|ping|tracert|nslookup|tasklist|taskkill|echo|type|dir|ls|cat|cp|mv|rm|mkdir|rmdir|del|copy|move|ren|sort|find|findstr|grep|sed|awk|tar|zip|unzip|7z|code|start|explorer|cd|cls|clear|exit|where|which)(\s|$)")) return false;

            // 2) 含中日韩文字 → 按自然语言处理
            if (CjkPattern.IsMatch(line)) return true;

            // 3) 英文：必须像一句话（至少 3 个词），且没有路径/参数/管道等命令痕迹
            if (line.IndexOf('\\') >= 0 || line.IndexOf('/') >= 0) return false;
            if (line.IndexOf('|') >= 0 || line.IndexOf('>') >= 0 || line.IndexOf('=') >= 0) return false;
            if (Regex.IsMatch(line, @"(^|\s)--?[A-Za-z]")) return false;                                  // -Path / --flag
            if (line.EndsWith("|") || line.EndsWith("\\")) return false;
            string[] words = Regex.Split(line, @"\s+");
            return words.Length >= 3;
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

                    return Sanitize(contentElement.GetString(), _options.MaxSuggestionLength, _options.AllowMultiLine);
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

        /// <summary>查缓存（带 TTL；过期就当没有）。</summary>
        private string GetCached(string line)
        {
            CacheEntry entry;
            if (!_cache.TryGetValue(line, out entry)) return null;
            if (_options.CacheTtlSeconds > 0 &&
                (DateTime.UtcNow - entry.Utc).TotalSeconds > _options.CacheTtlSeconds)
            {
                _cache.TryRemove(line, out _);
                return null;
            }
            return entry.Text;
        }

        private void Store(string line, string suggestion)
        {
            if (_cache.Count >= _options.MaxCacheEntries) _cache.Clear();
            _cache[line] = new CacheEntry { Text = suggestion, Utc = DateTime.UtcNow };
            LastError = string.Empty;
            Log("预测: " + line + "  =>  " + suggestion);
        }

        /// <summary>同一行同时最多一个在途请求；完成后自动写缓存（连按 Tab/Alt+P 不会重复打 API）。</summary>
        private Task<string> GetOrStartFetch(string line)
        {
            return _inflight.GetOrAdd(line, l =>
            {
                Task<string> task = FetchAsync(l);
                task.ContinueWith(done =>
                {
                    _inflight.TryRemove(l, out _);
                    if (done.Status == TaskStatus.RanToCompletion && !string.IsNullOrEmpty(done.Result))
                    {
                        Store(l, done.Result);
                    }
                }, TaskScheduler.Default);
                return task;
            });
        }

        private void Log(string message)
        {
            if (!_options.EnableLog || string.IsNullOrWhiteSpace(_options.LogPath)) return;
            try
            {
                lock (LogLock)
                {
                    // 超过 1MB 就清空重来，避免日志无限膨胀
                    var info = new FileInfo(_options.LogPath);
                    if (info.Exists && info.Length > 1024 * 1024) File.WriteAllText(_options.LogPath, string.Empty);

                    File.AppendAllText(_options.LogPath,
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine,
                        new UTF8Encoding(false));
                }
            }
            catch { }
        }

        // ---------------- 文本清洗 ----------------

        /// <summary>把模型输出整成可直接放进命令行的命令。说明文字会被丢弃；多行脚本按 allowMultiLine 决定是否返回。</summary>
        public static string Sanitize(string raw, int maxLength)
        {
            return Sanitize(raw, maxLength, true);
        }

        public static string Sanitize(string raw, int maxLength, bool allowMultiLine)
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

            // 1) 逐行清洗，并丢掉“说明文字/拒答”行
            var commands = new List<string>();
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
                if (IsProseLine(candidate)) continue;
                commands.Add(candidate);
            }

            if (commands.Count == 0) return null;   // 整段都是说明文字 → 不给建议

            // 2) 只有一行命令 → 直接用
            if (commands.Count == 1)
            {
                string single = commands[0];
                if (single.Length > maxLength) single = single.Substring(0, maxLength).TrimEnd();
                return single.Length == 0 ? null : single;
            }

            // 3) 多行：像脚本才返回；否则宁可不出建议，也绝不截取函数体中间的某一行
            if (!allowMultiLine || !LooksLikeScript(commands)) return null;

            string script = string.Join("\n", commands);
            if (script.Length > maxLength) script = script.Substring(0, maxLength).TrimEnd();
            return script.Length == 0 ? null : script;
        }

        /// <summary>这一行像不像“人话”（说明/抱歉/拒答），而不是命令。</summary>
        private static bool IsProseLine(string line)
        {
            if (CjkPattern.IsMatch(line))
            {
                // 中文里带命令特征（参数/管道/括号/引号/路径）才当命令，否则就是说明文字
                if (Regex.IsMatch(line, @"[|&$(){}\[\]`=]")) return false;
                if (line.IndexOf('-') >= 0) return false;
                if (line.IndexOf('\\') >= 0 || line.IndexOf('/') >= 0) return false;
                return true;
            }
            if (Regex.IsMatch(line, @"(?i)^(sorry|i can|i cannot|i am|please|here is|here are|the following|you can|note:|explanation:|this )")) return true;
            return false;
        }

        /// <summary>多行内容像不像一段脚本（而不是一句命令加几句解释）。</summary>
        private static bool LooksLikeScript(List<string> lines)
        {
            int commandish = 0;
            foreach (string line in lines)
            {
                if (ScoreLine(line) > 0 || line.IndexOf('|') >= 0) commandish++;
            }

            string joined = string.Join(" ", lines);
            // 有花括号 / 函数定义 / 变量 / 管道 → 明显是脚本
            if (joined.IndexOf('{') >= 0 || joined.IndexOf('}') >= 0) return true;
            if (joined.IndexOf("function ", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (joined.IndexOf('$') >= 0 || joined.IndexOf('|') >= 0) return true;
            // 每一行都是命令（比如两三条 cmdlet 串起来）→ 也当作脚本
            return commandish >= 2 && commandish == lines.Count;
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