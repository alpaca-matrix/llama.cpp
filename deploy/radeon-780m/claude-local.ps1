# Launch Claude Code against the local llama-server router.
# Usage: .\claude-local.ps1 [fast|deep] [extra claude args...]
param([string]$Model = "coder")

$env:ANTHROPIC_BASE_URL         = "http://192.168.254.250:8080"
$env:ANTHROPIC_AUTH_TOKEN       = "local"
$env:ANTHROPIC_MODEL            = $Model
$env:ANTHROPIC_SMALL_FAST_MODEL = $Model
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"

claude --model $Model @args
