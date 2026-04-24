#!/bin/bash
set -f

# ── --probe-bg subcommand ───────────────────────────────
# Source from your shell rc before starting `claude` to capture the terminal's
# real background via OSC 11 while the shell still owns the tty. Claude Code's
# own TUI does the same thing internally, but its statusline children can't —
# they're child processes with stdin=pipe. Writing the answer into
# CLAUDE_STATUSLINE_BG_HEX lets the statusline pick it up once claude starts.
#
# Usage in .bashrc / .zshrc / config.fish:
#   eval "$(~/.claude/statusline.sh --probe-bg)"
# ── --set-theme light|dark subcommand ──────────────────
# Write the theme cache for the CURRENT terminal window directly. Use this
# when your terminal switches dark/light independently of macOS system
# appearance (Zed, iTerm profile toggle, etc.) — bind it alongside your
# terminal's theme-toggle action so the statusline stays in sync.
#
# Usage:
#   statusline.sh --set-theme light
#   statusline.sh --set-theme dark
#   statusline.sh --set-theme auto   # clears override, re-detects on next render
if [ "$1" = "--set-theme" ]; then
    [ -z "$2" ] && { echo "usage: $0 --set-theme light|dark|auto" >&2; exit 2; }
    _tty_id=$(ps -o tty= -p $$ 2>/dev/null | tr -cd 'a-zA-Z0-9' | head -c 20)
    [ -z "$_tty_id" ] && _tty_id="ppid$PPID"
    # Write to a separate override file (not the auto-detection cache) so
    # background refresh never clobbers a manual choice.
    _override="/tmp/claude/statusline-theme-${TERM_PROGRAM:-unknown}-${_tty_id}.override"
    mkdir -p /tmp/claude
    case "$2" in
        light|dark) printf "%s" "$2" > "$_override" ;;
        auto) rm -f "$_override" ;;
        *) echo "invalid: $2 (expected light|dark|auto)" >&2; exit 2 ;;
    esac
    exit 0
fi

if [ "$1" = "--probe-bg" ]; then
    { exec </dev/tty; } 2>/dev/null || exit 0
    _saved_stty=$(stty -g 2>/dev/null) || exit 0
    stty -echo raw 2>/dev/null
    printf '\033]11;?\033\\' >/dev/tty 2>/dev/null
    reply=""
    IFS= read -rsn 128 -t 0.3 reply 2>/dev/null || true
    [ -n "$_saved_stty" ] && stty "$_saved_stty" 2>/dev/null
    bg_raw=$(printf '%s' "$reply" | sed -n 's/.*rgb:\([0-9a-fA-F]\{1,4\}\)\/\([0-9a-fA-F]\{1,4\}\)\/\([0-9a-fA-F]\{1,4\}\).*/\1 \2 \3/p')
    [ -z "$bg_raw" ] && exit 0
    hex=$(echo "$bg_raw" | awk '{
        for (i = 1; i <= 3; i++) {
            v = strtonum("0x" $i)
            maxv = 16 ^ length($i) - 1
            printf "%02x", int(v * 255 / maxv + 0.5)
        }
    }')
    [ -n "$hex" ] && echo "export CLAUDE_STATUSLINE_BG_HEX=\"#$hex\""
    exit 0
fi

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Theme detection (per-window cache, short TTL, background refresh) ───
# Key by TERM_PROGRAM + controlling tty so sibling windows in the same
# terminal app don't share (or corrupt) each other's cached value.
_tty_id=$(ps -o tty= -p $$ 2>/dev/null | tr -cd 'a-zA-Z0-9' | head -c 20)
[ -z "$_tty_id" ] && _tty_id="ppid$PPID"
_theme_override="/tmp/claude/statusline-theme-${TERM_PROGRAM:-unknown}-${_tty_id}.override"
_theme_cache="/tmp/claude/statusline-theme-${TERM_PROGRAM:-unknown}-${_tty_id}.txt"
# Short TTL so auto-detection catches system-appearance changes promptly.
# First render after a change still shows stale palette (background refresh
# writes to cache); subsequent renders use the new value. Acceptable since
# Claude re-renders statusline every prompt cycle.
_theme_cache_max_age=3
mkdir -p /tmp/claude

# Compute "light"|"dark" from a #RRGGBB hex string using Rec.709 luminance
# (matching Claude Code's own formula). Echoes result or nothing on failure.
_classify_hex() {
    local h="${1#\#}"
    [ ${#h} -lt 6 ] && return 1
    local r g b
    r=$(printf "%d" "0x${h:0:2}" 2>/dev/null) || return 1
    g=$(printf "%d" "0x${h:2:2}" 2>/dev/null) || return 1
    b=$(printf "%d" "0x${h:4:2}" 2>/dev/null) || return 1
    local lum=$(( (2126*r + 7152*g + 722*b) / 10000 ))
    [ "$lum" -gt 128 ] && echo light || echo dark
}

theme=""

# 1. Explicit env override — set by the installer when the user pinned a
#    fixed palette at install time, or exported manually in a shell rc.
case "$CLAUDE_STATUSLINE_THEME" in
    light|dark) theme="$CLAUDE_STATUSLINE_THEME" ;;
esac

# 2. Manual override file from --set-theme. Survives across renders until
#    cleared with `--set-theme auto`.
if [ -z "$theme" ] && [ -f "$_theme_override" ]; then
    _override_val=$(cat "$_theme_override" 2>/dev/null)
    case "$_override_val" in
        light|dark) theme="$_override_val" ;;
    esac
fi

# 3. CLAUDE_STATUSLINE_BG_HEX captured by `--probe-bg` in shell rc.
if [ -z "$theme" ] && [ -n "$CLAUDE_STATUSLINE_BG_HEX" ]; then
    _classified=$(_classify_hex "$CLAUDE_STATUSLINE_BG_HEX")
    [ -n "$_classified" ] && theme="$_classified"
fi

# 4. Per-window auto-detection cache. On a hit we still read the cached
#    value (so repeated renders stay consistent during the TTL), and only
#    skip the background refresh when the cache is fresh.
_theme_needs_refresh=true
if [ -f "$_theme_cache" ]; then
    _cache_mtime=$(stat -c %Y "$_theme_cache" 2>/dev/null || stat -f %m "$_theme_cache" 2>/dev/null)
    if [ -n "$_cache_mtime" ]; then
        _now_epoch=$(date +%s)
        _cache_age=$(( _now_epoch - _cache_mtime ))
        [ "$_cache_age" -lt "$_theme_cache_max_age" ] && _theme_needs_refresh=false
    fi
    if [ -z "$theme" ]; then
        _cached=$(cat "$_theme_cache" 2>/dev/null)
        case "$_cached" in
            light|dark) theme="$_cached" ;;
        esac
    fi
fi

# User pinned a theme — no point re-detecting.
case "$CLAUDE_STATUSLINE_THEME" in
    light|dark) _theme_needs_refresh=false ;;
esac

# 5. Default fallback — used on the very first render before the
#    background detector has written the cache.
[ -z "$theme" ] && theme="dark"

# 6. Kick off background refresh when the cache is stale. Detection reads
#    the terminal/system state and writes the cache; the next render picks
#    up the fresh value.
if $_theme_needs_refresh; then
    (
        detected=""

        # macOS system appearance — correct for any terminal that follows
        # the system (Zed, Terminal.app, iTerm in auto-switch mode, etc.).
        # Terminals locked to a non-system theme need CLAUDE_STATUSLINE_BG_HEX
        # (via `--probe-bg` in shell rc) or `--set-theme` bound to their
        # theme-toggle action.
        if [ "$(uname)" = "Darwin" ]; then
            if defaults read -g AppleInterfaceStyle >/dev/null 2>&1; then
                detected="dark"
            else
                detected="light"
            fi
        fi

        [ -z "$detected" ] && detected="dark"
        printf "%s" "$detected" > "$_theme_cache"
    ) >/dev/null 2>&1 &
fi

# ── Colors ──────────────────────────────────────────────
if [ "$theme" = "light" ]; then
    # Catppuccin Latte: softer, pastel-ish, designed for light backgrounds
    blue='\033[38;2;30;102;245m'          # blue
    blue_dim='\033[38;2;140;158;230m'     # softer lavender (brightness matched to cyan_dim/magenta_dim)
    orange='\033[38;2;254;100;11m'        # peach
    orange_bright='\033[38;2;254;120;50m' # peach (slightly lighter)
    orange_dim='\033[38;2;180;90;30m'     # muted peach
    orange_dark='\033[38;2;130;70;25m'    # deep peach
    green='\033[38;2;45;165;135m'         # green with mild teal shift
    green_dim='\033[38;2;110;190;170m'    # fresh mint, leaning teal
    cyan='\033[38;2;40;140;210m'          # sapphire, pushed bluer to separate from teal-ish green
    cyan_dim='\033[38;2;115;155;200m'     # soft muted sapphire
    red='\033[38;2;210;15;57m'            # red
    yellow='\033[38;2;223;142;29m'        # yellow
    yellow_dim='\033[38;2;215;180;130m'   # faded yellow
    white='\033[38;2;76;79;105m'          # text
    white_dim='\033[38;2;108;111;133m'    # subtext0
    magenta='\033[38;2;136;57;239m'       # mauve
    magenta_dim='\033[38;2;175;145;213m'  # muted mauve (brightness matched to cyan_dim)
    pink='\033[38;2;232;85;125m'          # pink-tinted red (used by context bar)
    pink_dim='\033[38;2;205;140;155m'     # muted pink-red (brightness matched to other _dim)
    ctx_info='\033[38;2;165;168;183m'     # faded gray (between overlay0 and surface2)
    sep_color='\033[38;2;200;204;216m'    # very pale surface0 tone — subtle separator
else
    blue='\033[38;2;160;200;245m'
    blue_dim='\033[38;2;100;135;175m'
    orange='\033[38;2;240;200;150m'
    orange_bright='\033[38;2;220;180;130m'
    orange_dim='\033[38;2;150;125;95m'
    orange_dark='\033[38;2;120;100;78m'
    green='\033[38;2;170;230;170m'
    green_dim='\033[38;2;85;120;85m'
    cyan='\033[38;2;130;200;220m'
    cyan_dim='\033[38;2;90;145;160m'
    red='\033[38;2;240;150;150m'
    yellow='\033[38;2;240;230;160m'
    yellow_dim='\033[38;2;170;165;115m'
    white='\033[38;2;210;215;220m'
    white_dim='\033[38;2;175;175;178m'
    magenta='\033[38;2;200;175;225m'
    magenta_dim='\033[38;2;130;115;142m'
    pink='\033[38;2;240;160;180m'
    pink_dim='\033[38;2;156;104;117m'
    ctx_info='\033[38;2;115;115;118m'
    sep_color=''                          # dark mode: rely on terminal dim attribute
fi
dim='\033[2m'
reset='\033[0m'

if [ -n "$sep_color" ]; then
    sep=" ${sep_color}│${reset} "
else
    sep=" ${dim}│${reset} "
fi

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    local bar_color=$3
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="━"; done
    for ((i=0; i<empty; i++)); do empty_str+="┅"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

format_epoch_time() {
    local epoch=$1
    local style=$2
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return

    local result=""
    case "$style" in
        time)
            result=$(date -j -r "$epoch" +"%-H:%M" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%-H:%M" 2>/dev/null)
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%-m/%-d %H:%M" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%-m/%-d %H:%M" 2>/dev/null)
            ;;
        *)
            result=$(date -j -r "$epoch" +"%-m/%-d" 2>/dev/null)
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%-m/%-d" 2>/dev/null)
            result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    printf "%s" "$result"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(env TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# ── Extract JSON data ───────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

# Format token count: 200000 → 200k, 1000000 → 1M
fmt_tokens() {
    local n=$1
    if [ "$n" -ge 1000000 ]; then
        echo "$(( n / 1000000 ))M"
    elif [ "$n" -ge 1000 ]; then
        echo "$(( n / 1000 ))k"
    else
        echo "$n"
    fi
}
current_fmt=$(fmt_tokens "$current")
size_fmt=$(fmt_tokens "$size")

effort="default"
settings_path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ -f "$settings_path" ]; then
    effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
fi

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Effort ──
pct_color=$(color_for_pct "$pct_used")
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
fi

git_worktree=$(echo "$input" | jq -r '.workspace.git_worktree // empty')
cc_version=$(echo "$input" | jq -r '.version // empty')

session_duration=""
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(iso_to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi


# Simplify model name: "Opus 4.6 (1M context)" → "Opus 4.6" + dim "(1M)"
model_base=$(echo "$model_name" | sed 's/ ([^)]*)//')
model_ctx=$(echo "$model_name" | sed -n 's/.*(\([^)]*\)).*/\1/p' | sed 's/ context//')
line1_left="${blue}${model_base}${reset}"
[ -n "$model_ctx" ] && line1_left+=" ${blue_dim}(${model_ctx})${reset}"

if [ "$pct_used" -ge 20 ]; then
    ctx_color="$pink"
    ctx_color_dim="$pink_dim"
else
    ctx_color="$green"
    ctx_color_dim="$green_dim"
fi
ctx_filled=$(( pct_used * 10 / 100 ))
ctx_empty=$(( 10 - ctx_filled ))
ctx_bar="${ctx_color}"
for ((i=0; i<ctx_filled; i++)); do ctx_bar+="█"; done
ctx_bar+="${dim}"
for ((i=0; i<ctx_empty; i++)); do ctx_bar+="░"; done
ctx_bar+="${reset}"
line1_right="${ctx_color} ${reset}${ctx_bar} ${ctx_color}${pct_used}%${reset} ${ctx_color_dim}(${current_fmt}/${size_fmt})${reset}"
# Prefer worktree label when present, otherwise fall back to branch.
git_label=""
git_icon=""
if [ -n "$git_worktree" ]; then
    git_label="$git_worktree"
    git_icon=$'\xef\x86\xbb'
elif [ -n "$git_branch" ]; then
    git_label="$git_branch"
    git_icon=$'\xef\x90\x98'
fi

if [ -n "$git_label" ]; then
    line1_left+="${sep}"
    line1_left+="${white_dim}${git_icon} ${git_label}${reset}"
    # Git diff stats (staged + unstaged + untracked)
    unstaged=$(git -C "$cwd" diff --shortstat 2>/dev/null)
    staged=$(git -C "$cwd" diff --cached --shortstat 2>/dev/null)
    untracked=$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    ins=0 del=0
    for stat_line in "$unstaged" "$staged"; do
        [ -z "$stat_line" ] && continue
        i=$(echo "$stat_line" | grep -o '[0-9]* insertion' | grep -o '[0-9]*')
        d=$(echo "$stat_line" | grep -o '[0-9]* deletion' | grep -o '[0-9]*')
        [ -n "$i" ] && ins=$(( ins + i ))
        [ -n "$d" ] && del=$(( del + d ))
    done
    git_changes=""
    [ "$ins" -gt 0 ] && git_changes+="${green}+${ins}${reset}"
    [ "$del" -gt 0 ] && { [ -n "$git_changes" ] && git_changes+=" "; git_changes+="${red}-${del}${reset}"; }
    [ "$untracked" -gt 0 ] && { [ -n "$git_changes" ] && git_changes+=" "; git_changes+="${yellow}?${untracked}${reset}"; }
    [ -n "$git_changes" ] && line1_left+=" ${white_dim}(${reset}${git_changes}${white_dim})${reset}"
fi
if [ -n "$session_duration" ]; then
    line1_left+="${sep}"
    line1_left+="${blue}󰔟 ${reset}${white}${session_duration}${reset}"
fi

# ── Rate limits from stdin (primary) ───────────────────
has_stdin_rates=false
five_hour_pct=""
five_hour_reset_epoch=""
seven_day_pct=""
seven_day_reset_epoch=""

stdin_five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$stdin_five_pct" ]; then
    has_stdin_rates=true
    five_hour_pct=$(printf "%.0f" "$stdin_five_pct")
    five_hour_reset_epoch=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | awk '{printf "%.0f", $1}')
    seven_day_reset_epoch=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
fi

# ── Fallback: API call (cached) ────────────────────────
_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
_cache_id=$(printf "%s" "$_config_dir" | md5 2>/dev/null || printf "%s" "$_config_dir" | md5sum 2>/dev/null | cut -d' ' -f1)
cache_file="/tmp/claude/statusline-usage-${_cache_id}.json"
cache_max_age=60
mkdir -p /tmp/claude

usage_data=""
extra_enabled="false"

if ! $has_stdin_rates; then
    needs_refresh=true

    if [ -f "$cache_file" ]; then
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        now=$(date +%s)
        cache_age=$(( now - cache_mtime ))
        if [ "$cache_age" -lt "$cache_max_age" ]; then
            needs_refresh=false
            usage_data=$(cat "$cache_file" 2>/dev/null)
        fi
    fi

    if $needs_refresh; then
        # Keychain service name: Claude Code suffixes the entry with the first 8
        # hex of sha256(CLAUDE_CONFIG_DIR) when that env var is explicitly set,
        # so a custom config dir must look up its own scoped credential entry
        # instead of falling through to the default ~/.claude one.
        keychain_services=("Claude Code-credentials")
        if [ -n "$CLAUDE_CONFIG_DIR" ]; then
            _svc_suffix=$(printf "%s" "$CLAUDE_CONFIG_DIR" | shasum -a 256 2>/dev/null | cut -c1-8)
            [ -n "$_svc_suffix" ] && keychain_services=("Claude Code-credentials-${_svc_suffix}" "${keychain_services[@]}")
        fi

        token=""
        if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
            token="$CLAUDE_CODE_OAUTH_TOKEN"
        elif command -v security >/dev/null 2>&1; then
            for svc in "${keychain_services[@]}"; do
                blob=$(security find-generic-password -s "$svc" -w 2>/dev/null)
                if [ -n "$blob" ]; then
                    token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
                    [ -n "$token" ] && [ "$token" != "null" ] && break
                fi
            done
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            creds_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
            if [ -f "$creds_file" ]; then
                token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
            fi
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            if command -v secret-tool >/dev/null 2>&1; then
                for svc in "${keychain_services[@]}"; do
                    blob=$(timeout 2 secret-tool lookup service "$svc" 2>/dev/null)
                    if [ -n "$blob" ]; then
                        token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
                        [ -n "$token" ] && [ "$token" != "null" ] && break
                    fi
                done
            fi
        fi

        if [ -n "$token" ] && [ "$token" != "null" ]; then
            response=$(curl -s --max-time 5 \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $token" \
                -H "anthropic-beta: oauth-2025-04-20" \
                -H "User-Agent: claude-code/2.1.34" \
                "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
            if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
                usage_data="$response"
                echo "$response" > "$cache_file"
            fi
        fi
        if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
            usage_data=$(cat "$cache_file" 2>/dev/null)
        fi
    fi

    if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
        five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
        five_hour_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
        five_hour_reset_epoch=$(iso_to_epoch "$five_hour_reset_iso")
        seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
        seven_day_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
        seven_day_reset_epoch=$(iso_to_epoch "$seven_day_reset_iso")

        extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    fi
else
    if [ -f "$cache_file" ]; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
        if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
            extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
        fi
    fi
fi

# ── Rate limit lines ────────────────────────────────────
line2_left=""
line3=""
bar_width=10

if [ -n "$five_hour_pct" ]; then
    five_hour_reset=$(format_epoch_time "$five_hour_reset_epoch" "time")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width" "$cyan")

    line2_left+="${cyan}5h${reset} ${five_hour_bar} ${cyan}${five_hour_pct}%${reset}"
    [ -n "$five_hour_reset" ] && line2_left+=" ${cyan_dim}󰑐 (${five_hour_reset})${reset}"
fi

if [ -n "$seven_day_pct" ]; then
    seven_day_reset=$(format_epoch_time "$seven_day_reset_epoch" "datetime")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width" "$magenta")

    [ -n "$line2_left" ] && line2_left+="${sep}"
    line2_left+="${magenta}7d${reset} ${seven_day_bar} ${magenta}${seven_day_pct}%${reset}"
    [ -n "$seven_day_reset" ] && line2_left+=" ${magenta_dim}󰑐 (${seven_day_reset})${reset}"
fi

if [ "$extra_enabled" = "true" ] && [ -n "$usage_data" ]; then
    extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
    extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')

    line3+="${white_dim}Extra${reset} ${white_dim}\$${extra_used}${reset}${ctx_info}/\$${extra_limit}${reset}"
fi

# ── Total cost (ccusage, cached) ───────────────────────
cost_cache="/tmp/claude/statusline-cost-${_cache_id}.txt"
cost_cache_max_age=1800
total_cost=""

today_cost=""

ccusage_query='(.daily[-1].totalCost // 0 | tostring) + ":" + (.totals.totalCost // 0 | tostring)'

if command -v ccusage >/dev/null 2>&1; then
    cost_needs_refresh=true
    if [ -f "$cost_cache" ]; then
        cost_mtime=$(stat -c %Y "$cost_cache" 2>/dev/null || stat -f %m "$cost_cache" 2>/dev/null)
        cost_now=$(date +%s)
        cost_age=$(( cost_now - cost_mtime ))
        [ "$cost_age" -lt "$cost_cache_max_age" ] && cost_needs_refresh=false
    fi

    if $cost_needs_refresh; then
        # Always refresh in the background so rendering never blocks on
        # ccusage — its full-history JSONL scan can take 8+ seconds even in
        # --offline mode, far longer than a statusline render budget. The
        # tradeoff: the very first render after install shows no cost line;
        # the next render (after the background job finishes) picks it up.
        # A lockfile prevents multiple stale renders from spawning piles of
        # concurrent ccusage processes.
        #
        # Online mode (no --offline) is required so newly released model ids
        # price correctly — offline silently underprices anything missing
        # from its bundled table (opus-4-7 1M was charged ~70x low).
        cost_lock="${cost_cache}.lock"
        if mkdir "$cost_lock" 2>/dev/null; then
            (
                trap 'rmdir "$cost_lock" 2>/dev/null' EXIT
                ccusage daily --json 2>/dev/null \
                    | jq -r "$ccusage_query" \
                    | awk -F: '{printf "%.2f:%.2f", $1, $2}' > "${cost_cache}.tmp" \
                    && mv "${cost_cache}.tmp" "$cost_cache"
            ) >/dev/null 2>&1 &
        fi
    fi

    # Always read from cache (may be stale on first run)
    if [ -f "$cost_cache" ]; then
        cached=$(cat "$cost_cache" 2>/dev/null)
        today_cost="${cached%%:*}"
        total_cost="${cached##*:}"
    fi
fi

# ── Output ──────────────────────────────────────────────
# Line 1: model | branch (diff) | session | context bar — all left-aligned
line1="$line1_left${sep}$line1_right"
printf "%b" "$line1"

# Line 2: 5h | 7d — all left-aligned
if [ -n "$line2_left" ]; then
    printf "\n\n"
    printf "%b" "$line2_left"
fi

# Line 3: $today → $total | Extra
line3_cost=""
if [ -n "$today_cost" ] || [ -n "$total_cost" ]; then
    line3_cost+="${yellow}Cost${reset} "
    [ -n "$today_cost" ] && line3_cost+="${yellow}\$${today_cost}${reset}"
    [ -n "$today_cost" ] && [ -n "$total_cost" ] && line3_cost+=" ${yellow_dim}→${reset} "
    [ -n "$total_cost" ] && line3_cost+="${yellow}\$${total_cost}${reset}"
fi

line3_combined="$line3_cost"
if [ -n "$line3" ]; then
    [ -n "$line3_combined" ] && line3_combined+="${sep}"
    line3_combined+="$line3"
fi
if [ -n "$cc_version" ]; then
    [ -n "$line3_combined" ] && line3_combined+="${sep}"
    line3_combined+="${ctx_info}v${cc_version}${reset}"
fi

if [ -n "$line3_combined" ]; then
    printf "\n"
    printf "%b" "$line3_combined"
fi

exit 0
