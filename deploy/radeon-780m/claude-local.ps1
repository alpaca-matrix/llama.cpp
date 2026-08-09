# Launch Claude Code against the local llama-server router.
# Usage: .\claude-local.ps1 [fast|coder|assist|deep] [extra claude args...]
# Default is fast: it beats coder on every SWE-bench variant (75.6/50.4/69.3 vs
# 70.6/44.3/62.8) at +38% tg, +30% pp and less than half the resident size.
#
# The routing is ephemeral. $env: writes go to the *process* environment and a
# .ps1 does not run in its own process, so setting them naively would leave the
# shell pointed at the box after this exits - a later bare `claude` in the same
# window would silently keep using local models. Every variable is saved and
# restored in the finally block, so `claude` on its own always means Anthropic.
param(
    [ValidateSet("fast", "coder", "assist", "deep", "nerkyor-eval", "laguna-eval", "kat-eval")]
    [string]$Model = "fast",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ClaudeArgs
)

$local = @{
    ANTHROPIC_BASE_URL                       = "http://192.168.254.250:8080"
    ANTHROPIC_AUTH_TOKEN                     = "local"
    ANTHROPIC_MODEL                          = $Model
    ANTHROPIC_SMALL_FAST_MODEL               = $Model
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
}

# capture the prior values (null means "was not set") so they can be put back
$saved = @{}
foreach ($name in $local.Keys) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    foreach ($name in $local.Keys) {
        [Environment]::SetEnvironmentVariable($name, $local[$name])
    }
    claude --model $Model @ClaudeArgs
}
finally {
    # SetEnvironmentVariable with $null removes the variable outright, which is
    # what restores a "was never set" state - assigning "" would leave it defined
    foreach ($name in $local.Keys) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name])
    }
}
