# Launch Claude Code against the local llama-server router.
# Usage: .\claude-local.ps1 [fast|coder|assist|deep] [extra claude args...]
# Default is fast: it beats coder on every SWE-bench variant (75.6/50.4/69.3 vs
# 70.6/44.3/62.8) at +38% tg, +30% pp and less than half the resident size.
param([string]$Model = "fast")

$env:ANTHROPIC_BASE_URL         = "http://192.168.254.250:8080"
$env:ANTHROPIC_AUTH_TOKEN       = "local"
$env:ANTHROPIC_MODEL            = $Model
$env:ANTHROPIC_SMALL_FAST_MODEL = $Model
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"

claude --model $Model @args
