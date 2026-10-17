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
        public bool LogInputs { get; set; } = false;         // 日志里是否记录原始输入（默认只记长度/语言）
        public int CandidateCount { get; set; } = 3;          // Tab 一次给几个候选方案
        public bool EnableMultiCandidate { get; set; } = true;
        public double PriceInPerM { get; set; } = 0;          // 每百万输入 token 的价格（0 = 只显示 token 数）
        public double PriceOutPerM { get; set; } = 0;
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

        /// <summary>运行统计快照（供 Get-AIPredictorStatus -Stats 展示）。</summary>
        public sealed class AIPredictorStats
        {
            public long Requests { get; set; }
            public long Failures { get; set; }
            public long CacheHits { get; set; }
            public long CacheMisses { get; set; }
            public long InlineHits { get; set; }
            public long SafetyBlocks { get; set; }
            public long PromptTokens { get; set; }
            public long CompletionTokens { get; set; }
            public double TotalLatencyMs { get; set; }
            public double LastLatencyMs { get; set; }
            public double AvgLatencyMs { get { return Requests > 0 ? Math.Round(TotalLatencyMs / Requests, 0) : 0; } }
            public double HitRate { get { long t = CacheHits + CacheMisses; return t > 0 ? Math.Round(100.0 * CacheHits / t, 1) : 0; } }
        }

        /// <summary>高风险命令规则：正则 → 人话原因。</summary>
        private static readonly string[,] DangerRules = new string[,]
        {
            { @"(?i)\bremove-item\b.*-recurse", "递归删除文件/目录" },
            { @"(?i)\bremove-item\b.*-force", "强制删除（不进回收站）" },
            { @"(?i)\b(rd|rmdir)\b.*/s", "递归删除目录" },
            { @"(?i)\brm\b.*-r", "递归删除" },
            { @"(?i)\bdel\b.*/f", "强制删除文件" },
            { @"(?i)\bformat-volume\b", "格式化卷（数据全丢）" },
            { @"(?i)\b(clear-disk|initialize-disk)\b", "清空/初始化磁盘（数据全丢）" },
            { @"(?i)\b(stop-computer|restart-computer)\b", "关机 / 重启" },
            { @"(?i)\bclear-recyclebin\b", "清空回收站" },
            { @"(?i)\bgit\s+reset\s+--hard\b", "丢弃所有未提交改动" },
            { @"(?i)\bgit\s+clean\s+-[a-z]*f", "强制删除未跟踪文件" },
            { @"(?i)\bset-executionpolicy\b.*unrestricted", "降低执行策略限制" },
            { @"(?i)\b(invoke-expression|iex)\b", "动态执行字符串（可被注入）" },
            { @"(?i)\breg\s+delete\b", "删除注册表项" },
            { @"(?i)\bicacls\b.*(/grant|/reset)", "修改文件权限" },
            { @"(?i)\btakeown\b", "夺取文件所有权" },
            { @"(?i)\bset-mppreference\b.*disable", "关闭杀毒防护" },
            { @"(?i)\bnetsh\b.*firewall", "修改防火墙" }
        };

        // 多个候选方案的在途请求（Tab 连按不重复打 API）
        private readonly ConcurrentDictionary<string, Task<string[]>> _inflightMulti =
            new ConcurrentDictionary<string, Task<string[]>>(StringComparer.Ordinal);

        // 运行统计（用量面板）
        private long _requests, _failures, _cacheHits, _cacheMisses, _inlineHits, _safetyBlocks, _promptTokens, _completionTokens;
        private double _totalLatencyMs, _lastLatencyMs;

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
                // 不逐键记录输入（隐私 + 降噪）；真正发请求由 PumpRequests 记录
                if (!string.IsNullOrEmpty(suggestion) && !multiLine)
                {
                    Interlocked.Increment(ref _inlineHits);
                    Log("行内建议显示: " + Describe(line));
                }
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
            Log("已采纳: " + (_options.LogInputs ? acceptedSuggestion : "len=" + acceptedSuggestion.Length));
        }

        public void OnSuggestionDisplayed(PredictionClient client, uint session, int countOrLength) { }
        public void OnCommandLineAccepted(PredictionClient client, IReadOnlyList<string> history) { }
        public void OnCommandLineExecuted(PredictionClient client, string commandLine, bool success) { }

        // ---------------- 对外（PowerShell 调用）----------------

        public string LastError { get; private set; } = string.Empty;
        public int CacheCount => _cache.Count;
        public bool HasApiKey => !string.IsNullOrWhiteSpace(_options.ApiKey);

        /// <summary>运行统计快照。</summary>
        public AIPredictorStats Stats
        {
            get
            {
                return new AIPredictorStats
                {
                    Requests = Interlocked.Read(ref _requests),
                    Failures = Interlocked.Read(ref _failures),
                    CacheHits = Interlocked.Read(ref _cacheHits),
                    CacheMisses = Interlocked.Read(ref _cacheMisses),
                    InlineHits = Interlocked.Read(ref _inlineHits),
                    SafetyBlocks = Interlocked.Read(ref _safetyBlocks),
                    PromptTokens = Interlocked.Read(ref _promptTokens),
                    CompletionTokens = Interlocked.Read(ref _completionTokens),
                    TotalLatencyMs = _totalLatencyMs,
                    LastLatencyMs = _lastLatencyMs
                };
            }
        }

        /// <summary>记录一次“安全刹车”（高风险建议被拦截或被警告）。</summary>
        public void NoteSafetyBlock() { Interlocked.Increment(ref _safetyBlocks); }

        /// <summary>判断命令是否高风险；返回人话原因（null = 安全）。</summary>
        public static string GetDangerReason(string command)
        {
            if (string.IsNullOrWhiteSpace(command)) return null;
            for (int i = 0; i < DangerRules.GetLength(0); i++)
            {
                if (Regex.IsMatch(command, DangerRules[i, 0])) return DangerRules[i, 1];
            }
            return null;
        }

        /// <summary>查缓存；未命中则安排后台请求并返回 null。</summary>
        public string Lookup(string line)
        {
            if (!IsEligible(line)) return null;
            line = line.Trim();

            string cached = GetCached(line);
            if (cached != null) { Interlocked.Increment(ref _cacheHits); return cached; }
            Interlocked.Increment(ref _cacheMisses);

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
            if (cached != null) { Interlocked.Increment(ref _cacheHits); return cached; }
            Interlocked.Increment(ref _cacheMisses);

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

            Log("发起请求: " + Describe(line));
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
            string content = await CallModelAsync(line, null).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(content)) return null;
            return Sanitize(content, _options.MaxSuggestionLength, _options.AllowMultiLine);
        }

        /// <summary>发一次 chat 请求，返回模型原始文本；失败返回 null 并设置 LastError。</summary>
        private async Task<string> CallModelAsync(string userContent, string extraInstruction)
        {
            if (!HasApiKey) { LastError = "未配置 ApiKey"; return null; }

            string system = BuildSystemPrompt();
            if (!string.IsNullOrWhiteSpace(extraInstruction)) system = system + "\n\n" + extraInstruction;

            var messages = new List<object>
            {
                new { role = "system", content = system },
                new { role = "user", content = userContent }
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
            var watch = System.Diagnostics.Stopwatch.StartNew();
            Interlocked.Increment(ref _requests);

            try
            {
                using (var content = new StringContent(json, Encoding.UTF8, "application/json"))
                using (HttpResponseMessage response = await _client.PostAsync(_options.Endpoint, content).ConfigureAwait(false))
                {
                    string body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    if (!response.IsSuccessStatusCode)
                    {
                        Interlocked.Increment(ref _failures);
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
                            Interlocked.Increment(ref _failures);
                            LastError = "响应中没有 choices";
                            return null;
                        }

                        JsonElement message;
                        JsonElement contentElement;
                        if (!choices[0].TryGetProperty("message", out message) ||
                            !message.TryGetProperty("content", out contentElement))
                        {
                            Interlocked.Increment(ref _failures);
                            LastError = "响应结构不认识";
                            return null;
                        }

                        JsonElement usage;
                        if (root.TryGetProperty("usage", out usage))
                        {
                            JsonElement token;
                            if (usage.TryGetProperty("prompt_tokens", out token)) Interlocked.Add(ref _promptTokens, token.GetInt64());
                            if (usage.TryGetProperty("completion_tokens", out token)) Interlocked.Add(ref _completionTokens, token.GetInt64());
                        }

                        return contentElement.GetString();
                    }
                }
            }
            catch (Exception ex)
            {
                Interlocked.Increment(ref _failures);
                LastError = ex.Message;
                Log("请求异常: " + ex.Message);
                return null;
            }
            finally
            {
                watch.Stop();
                _lastLatencyMs = watch.Elapsed.TotalMilliseconds;
                _totalLatencyMs += _lastLatencyMs;
                Log("请求耗时: " + (int)_lastLatencyMs + " ms");
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
            Log("预测: " + Describe(line) + "  =>  " + (_options.LogInputs ? suggestion : "len=" + suggestion.Length));
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

        /// <summary>一次请求拿多个候选方案（Tab 菜单用）；命中单条缓存时直接返回那一条。</summary>
        public string[] QueryCandidates(string line, int timeoutMs, int count)
        {
            if (!IsEligible(line)) return new string[0];
            line = line.Trim();
            if (count < 1) count = 1;

            string cached = GetCached(line);
            if (cached != null) { Interlocked.Increment(ref _cacheHits); return new[] { cached }; }
            Interlocked.Increment(ref _cacheMisses);

            if (!_options.EnableMultiCandidate || count <= 1)
            {
                string single = Query(line, timeoutMs);
                return string.IsNullOrEmpty(single) ? new string[0] : new[] { single };
            }

            int wait = Math.Max(1000, timeoutMs);
            try
            {
                Task<string[]> task = GetOrStartFetchCandidates(line, count);
                if (task.Wait(wait))
                {
                    string[] result = task.Result;
                    if (result != null && result.Length > 0) return result;
                    LastError = "模型没有给出可用的候选命令";
                }
                else
                {
                    LastError = "请求超时（" + wait + " ms），结果到了会进缓存，可稍后再按一次";
                }
            }
            catch (Exception ex)
            {
                LastError = ex.Message;
                Log("候选查询失败: " + ex.Message);
            }
            return new string[0];
        }

        private Task<string[]> GetOrStartFetchCandidates(string line, int count)
        {
            return _inflightMulti.GetOrAdd(line, l =>
            {
                Task<string[]> task = FetchCandidatesAsync(l, count);
                task.ContinueWith(done =>
                {
                    _inflightMulti.TryRemove(l, out _);
                    if (done.Status == TaskStatus.RanToCompletion && done.Result != null && done.Result.Length > 0)
                    {
                        Store(l, done.Result[0]);   // 第一条同时进单条缓存，Alt+P 可直接用
                    }
                }, TaskScheduler.Default);
                return task;
            });
        }

        private async Task<string[]> FetchCandidatesAsync(string line, int count)
        {
            string instruction =
                "这次请给出 " + count + " 个不同思路的 PowerShell 实现方案。" +
                "每个方案单独一行、只写命令本身，不要编号、不要解释、不要 Markdown 代码块。" +
                "优先给出风险最低的方案，再给更简洁或更彻底的方案。";
            string content = await CallModelAsync(line, instruction).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(content)) return new string[0];

            var result = new List<string>();
            foreach (string rawLine in content.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
            {
                string one = Sanitize(rawLine, _options.MaxSuggestionLength, false);
                if (string.IsNullOrEmpty(one)) continue;
                if (result.Contains(one)) continue;
                result.Add(one);
                if (result.Count >= count) break;
            }
            return result.ToArray();
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

        /// <summary>日志里描述一段输入：默认只记长度和语言；LogInputs=true 时才记原文。</summary>
        private string Describe(string line)
        {
            if (string.IsNullOrEmpty(line)) return "(空)";
            if (_options.LogInputs) return "\"" + Shorten(line, 80) + "\"";
            return "len=" + line.Length + " lang=" + (CjkPattern.IsMatch(line) ? "zh" : "en");
        }

        private static string Shorten(string value, int max)
        {
            if (string.IsNullOrEmpty(value)) return string.Empty;
            value = value.Replace("\n", " ").Replace("\r", " ").Trim();
            return value.Length <= max ? value : value.Substring(0, max) + "…";
        }
    }
}