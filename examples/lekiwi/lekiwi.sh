#!/usr/bin/env bash
#
# lekiwi.sh — control center for the LeKiwi (lerobot) robot workflow.
# ===================================================================
# A single front door with a modern arrow-key TUI. Merges the old lekiwi_host.sh
# (launch/kill the Pi host over SSH) with the laptop-side lerobot-* CLIs
# (teleop / record / replay / calibrate). Zero dependencies — pure ANSI, so it
# works the same on the laptop and on the robot.  (Supersedes lekiwi_host.sh.)
#
#   ./examples/lekiwi/lekiwi.sh              # modern pop-up menu (↑↓ move, ⏎ select)
#   ./examples/lekiwi/lekiwi.sh teleop       # jump straight to an action
#   ./examples/lekiwi/lekiwi.sh host-launch  # == old `lekiwi_host.sh launch` (asks minutes)
#   ./examples/lekiwi/lekiwi.sh host-kill    # == old `lekiwi_host.sh kill`
#
# Actions: host-launch  host-kill  teleop  record  replay  view  calibrate  train  eval  settings
#          (train = lerobot-train, LOCAL GPU only — wandb/hub off; eval = lerobot-rollout;
#           view = lerobot-dataset-viz in Rerun)
#
# Run host-launch in ONE terminal (it holds the live session); use a SECOND
# terminal for teleop/record.
#
# Config — env var at launch ▸ lekiwi.conf (at the work dir, see Paths below) ▸
# built-in default. Edit persistently via the `settings` action (or the ⚙ menu
# item); see CONFIG_SPEC for all keys:
#   laptop → LAPTOP_ENV MAMBA_ROOT LEADER_PORT LEADER_ID
#   robot  → LEKIWI_HOST ROBOT_ID CONNECTION_TIME CONDA_ENV
#   eval   → POLICY_PATH POLICY_ROOT INFERENCE EXECUTION_HORIZON DISPLAY_DATA
#
set -euo pipefail

# ── Paths — detect layout, then cd to WORK_DIR so datasets/ etc. land there ──
# in-repo:        script lives in examples/lekiwi/ of a lerobot checkout — the
#                 yamls sit NEXT TO it, work dir = the repo root (../..).
# parent-project: script copied out to a project root holding a lerobot/ clone —
#                 yamls under lerobot/examples/lekiwi, work dir = that root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lekiwi_robot.yaml" ]; then
    CFG_DIR="$SCRIPT_DIR"
    WORK_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
    CFG_DIR="$SCRIPT_DIR/lerobot/examples/lekiwi"
    WORK_DIR="$SCRIPT_DIR"
fi
cd "$WORK_DIR"
# Self-reference for help hints (`./$SELF …`) — relative to WORK_DIR so the
# printed commands are copy-pastable from where the user actually stands.
SELF="$(basename "$0")"
[ "$WORK_DIR" != "$SCRIPT_DIR" ] && SELF="${SCRIPT_DIR#"$WORK_DIR"/}/$SELF"
CFG_TELEOP="$CFG_DIR/lekiwi_teleop.yaml"
CFG_RECORD="$CFG_DIR/lekiwi_record.yaml"
CFG_REPLAY="$CFG_DIR/lekiwi_replay.yaml"
CFG_ROLLOUT="$CFG_DIR/lekiwi_rollout.yaml"
CFG_TRAIN="$CFG_DIR/lekiwi_train.yaml"

# ── Config (env var at launch ▸ lekiwi.conf ▸ built-in default) ──
# CONFIG_SPEC is the single source of truth — key|kind|hint — driving default
# application (config_load), lekiwi.conf parse/save, and the ⚙ Settings form.
# kinds: text | path | int | enum:<a>,<b>   (path = default expands $HOME/$WORK_DIR)
# Some related values live in the lerobot yamls, NOT here (the hints say which):
# e.g. the client's remote_ip/id are in lekiwi_robot.yaml, teleop.port in the
# record/teleop yamls. This registry only covers the launcher's own knobs.
CONF_FILE="$WORK_DIR/lekiwi.conf"
CONFIG_SPEC=(
    "LAPTOP_ENV|text|laptop conda env for the lerobot CLIs"
    "MAMBA_ROOT|path|conda root (holds etc/profile.d/conda.sh)"
    "LEADER_PORT|text|leader serial port — calibrate only (record/teleop use teleop.port in yaml)"
    "LEADER_ID|text|leader calibration id — calibrate only"
    "LEKIWI_HOST|text|SSH host for host-launch/kill (client remote_ip is in lekiwi_robot.yaml)"
    "ROBOT_ID|text|--robot.id for the Pi host (client id is in the yaml)"
    "CONNECTION_TIME|int|host session seconds (menu asks minutes; ←→ steps by 60)"
    "CONDA_ENV|text|REMOTE Pi env — NOT the laptop env"
    "POLICY_PATH|path|default eval checkpoint — RELATIVE to POLICY_ROOT; empty = auto (newest)"
    "POLICY_ROOT|path|eval scans here for checkpoints to pick from"
    "INFERENCE|enum:sync,rtc|eval backend — rtc = Real-Time Chunking, smoother for slow VLAs"
    "EXECUTION_HORIZON|int|rtc blend window — keep ABOVE the inference delay (~20–25 for SmolVLA)"
    "DISPLAY_DATA|enum:off,on|eval Rerun live view default for non-TTY runs"
)

config_default() {  # built-in default per key — the ONLY place $HOME/$WORK_DIR expand
    case "$1" in
        LAPTOP_ENV)        echo "lerobot" ;;
        MAMBA_ROOT)        echo "$HOME/miniforge3" ;;
        LEADER_PORT)       echo "/dev/ttyACM0" ;;
        LEADER_ID)         echo "lekiwi_leader" ;;
        LEKIWI_HOST)       echo "lekiwi" ;;
        ROBOT_ID)          echo "lekiwi" ;;
        CONNECTION_TIME)   echo "600" ;;
        CONDA_ENV)         echo "lekiwi" ;;
        POLICY_PATH)       echo "" ;;   # empty = auto: newest checkpoint under POLICY_ROOT
        POLICY_ROOT)       echo "$WORK_DIR/smolvla_lekiwi" ;;
        INFERENCE)         echo "sync" ;;
        EXECUTION_HORIZON) echo "20" ;;
        DISPLAY_DATA)      echo "off" ;;   # legacy 1/true/yes/on still accepted by do_eval
    esac
}

config_is_key() { local e; for e in "${CONFIG_SPEC[@]}"; do [ "${e%%|*}" = "$1" ] && return 0; done; return 1; }

# Parse (do NOT source) KEY=value lines: only whitelisted keys are assigned, the
# value is the literal remainder after the first '=' (exactly what config_save
# writes — keep the two matched, never quote/escape on one side only). Parsing
# means a broken or hostile conf can't run code or kill the launcher via set -e.
# Env-set keys are skipped: an explicit env var at launch beats the conf.
config_parse_file() {
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; *=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        config_is_key "$key" || continue
        [ -n "${CONFIG_ENV_SET[$key]+x}" ] && continue
        printf -v "$key" '%s' "$val"
    done < "$1"
    return 0
}

declare -A CONFIG_ENV_SET=()   # keys set in the environment at launch (precedence + ⚙ provenance tag)
_CONFIG_SNAPPED=0
config_load() {
    local e key
    if [ "$_CONFIG_SNAPPED" != 1 ]; then   # snapshot ONCE — a re-run must not tag conf values as env
        for e in "${CONFIG_SPEC[@]}"; do
            key="${e%%|*}"
            [ -n "${!key+x}" ] && CONFIG_ENV_SET["$key"]=1
        done
        _CONFIG_SNAPPED=1
    fi
    [ -f "$CONF_FILE" ] && config_parse_file "$CONF_FILE"
    for e in "${CONFIG_SPEC[@]}"; do       # built-in defaults fill whatever is still unset
        key="${e%%|*}"
        [ -n "${!key+x}" ] || printf -v "$key" '%s' "$(config_default "$key")"
    done
    # Pre-2026-06 confs stored DISPLAY_DATA= (empty meant off); normalize so the
    # conf round-trips a real enum value from now on.
    [ -z "$DISPLAY_DATA" ] && DISPLAY_DATA=off
    return 0
}

config_save() {  # config_save <assoc-name> — atomic rewrite of lekiwi.conf (raw KEY=value lines)
    local -n _cs_vals="$1"
    local tmp="$CONF_FILE.tmp.$$" e key
    {
        printf '# lekiwi.conf — written by ./%s settings (%s)\n' "$SELF" "$(date '+%Y-%m-%d %H:%M')"
        printf '# Precedence: env var at launch > this file > built-in default.\n\n'
        for e in "${CONFIG_SPEC[@]}"; do
            key="${e%%|*}"
            printf '%s=%s\n' "$key" "${_cs_vals[$key]}"
        done
    } > "$tmp" && mv -f "$tmp" "$CONF_FILE"
}

# ── Theme (256-color, robotics palette; degrades to plain when not a TTY) ──
setup_colors() {
    if [ -t 1 ] || [ "${FORCE_COLOR:-}" = 1 ]; then
        local e=$'\e'
        R="$e[0m"; B="$e[1m"; DIM="$e[2m"
        ACC="$e[38;5;43m"        # teal-cyan accent
        AMBER="$e[38;5;214m"     # warm secondary
        OKC="$e[38;5;42m"        # green
        ERRC="$e[38;5;203m"      # red
        SECT="$e[1;38;5;245m"    # section labels
        BORD="$e[38;5;240m"      # rules
    else
        R='' B='' DIM='' ACC='' AMBER='' OKC='' ERRC='' SECT='' BORD=''
    fi
}
RULE_HEAVY='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
RULE_LIGHT='──────────────────────────────────────────────────────'

GPU_STATUS="" GPU_NAME=""
compute_status() {
    local name; name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
    name="${name#NVIDIA }"; name="${name#GeForce }"
    GPU_NAME="$name"   # plain (uncolored) — eval uses it for device auto-detect
    if [ -n "$name" ]; then GPU_STATUS="${OKC}●${R} ${DIM}${name}${R}"; else GPU_STATUS="${DIM}none${R}"; fi
}

# ── Laptop env activation (lazy: host SSH actions don't need it) ──
_ENV_READY=0
ensure_local_env() {
    [ "$_ENV_READY" = 1 ] && return 0
    local sh="$MAMBA_ROOT/etc/profile.d/conda.sh"
    [ -f "$sh" ] || { echo "${ERRC}✗${R} conda.sh not found at $sh — set MAMBA_ROOT." >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$sh"
    conda activate "$LAPTOP_ENV" || { echo "${ERRC}✗${R} could not activate '$LAPTOP_ENV'." >&2; exit 1; }
    _ENV_READY=1
}

banner() { printf '\n%s▶ %s%s\n  %slaptop env: %s · cwd: %s%s\n\n' "$ACC" "$*" "$R" "$DIM" "$LAPTOP_ENV" "$WORK_DIR" "$R"; }

ask_minutes() {
    local def_min=$(( CONNECTION_TIME / 60 )); [ "$def_min" -lt 1 ] && def_min=1
    if [ -t 0 ]; then
        printf '  %s⏱  Session length in minutes%s %s[%s]%s ' "$ACC" "$R" "$DIM" "$def_min" "$R"
        local m; flush_typeahead; read -r m || m=''
        m="${m:-$def_min}"
        if [[ "$m" =~ ^[0-9]+$ ]] && [ "$m" -ge 1 ]; then CONNECTION_TIME=$(( m * 60 ))
        else CONNECTION_TIME=$(( def_min * 60 )); printf '  %sinvalid — using %s min%s\n' "$DIM" "$def_min" "$R"; fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ROBOT / Pi HOST over SSH  (logic merged from lekiwi_host.sh)
# ─────────────────────────────────────────────────────────────────────────────
# The raw SSH session (logs stream live, terminal is held). Kept separate so the
# countdown wrapper and the no-TTY fallback share exactly one definition.
_host_ssh() {
    # Ctrl+C stops the host gracefully, then force-kills if it wedges. The host
    # is run BACKGROUNDED under `wait` so this shell's INT trap fires immediately
    # (a foreground child would defer it until the child returns — useless when
    # the host hangs on servo comms). The inner `trap - INT TERM` restores default
    # signal disposition so the host still receives Ctrl+C and runs its own clean
    # disconnect — an async `&` job otherwise inherits SIG_IGN and could never
    # catch it. GRACE = seconds to allow for a clean shutdown before SIGKILL.
    ssh -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=3 \
        -t "${LEKIWI_HOST}" "
        GRACE=5
        cleanup() {
            echo
            echo '🛑 Stopping LeKiwi host…'
            i=0; while [ \"\$i\" -lt \"\$GRACE\" ]; do kill -0 \"\$PID\" 2>/dev/null || break; sleep 1; i=\$(( i + 1 )); done
            if kill -0 \"\$PID\" 2>/dev/null; then
                echo '⚠️  host did not exit in time — forcing kill'
                kill -s KILL \"\$PID\" 2>/dev/null || true
            fi
            kill \"\$WPID\" 2>/dev/null || true
            exit 130
        }
        trap cleanup INT TERM

        eval \"\$(~/miniforge3/bin/mamba shell hook --shell bash)\" || exit 1
        mamba activate ${CONDA_ENV} || { echo '✗ could not activate ${CONDA_ENV}' >&2; exit 1; }

        ( trap - INT TERM; exec python -m lerobot.robots.lekiwi.lekiwi_host \
            --robot.id=${ROBOT_ID} \
            --host.connection_time_s=${CONNECTION_TIME} ) &
        PID=\$!

        # Overrun safety net: if the host outlives its session by ~60s (wedged on
        # servo comms), nudge then force-kill so this never hangs forever.
        ( sleep \$(( ${CONNECTION_TIME} + 60 ))
          echo '⚠️  session overran — stopping host' >&2
          kill -s INT \"\$PID\" 2>/dev/null
          sleep \$GRACE
          kill -s KILL \"\$PID\" 2>/dev/null ) &
        WPID=\$!

        wait \"\$PID\"; RC=\$?
        kill \"\$WPID\" 2>/dev/null || true
        exit \$RC
    "
}

# Background loop that repaints the pinned status bar on the bottom row once a
# second. Runs as a subshell (called with &) so `set +e` here can't leak out and
# so terminal-generated Ctrl+C (which hits the foreground group only) never
# reaches it — it lives until _host_bar_cleanup kills it.
#   _host_bar_loop <start_epoch> <total_secs> <bottom_row> <bar_width> <time_width>
_host_bar_loop() {
    set +e
    local start=$1 total=$2 row=$3 barw=$4 tw=$5
    local now elapsed remaining pct filled timestr fill empty line mm ss
    while :; do
        now=$(date +%s)
        elapsed=$(( now - start ));            [ "$elapsed" -lt 0 ] && elapsed=0
        remaining=$(( total - elapsed ));      [ "$remaining" -lt 0 ] && remaining=0
        if [ "$total" -gt 0 ]; then pct=$(( elapsed * 100 / total )); else pct=100; fi
        [ "$pct" -gt 100 ] && pct=100
        filled=$(( pct * barw / 100 ))
        mm=$(( remaining / 60 )); ss=$(( remaining % 60 ))
        printf -v timestr '%d:%02d' "$mm" "$ss"
        printf -v timestr '%*s' "$tw" "$timestr"   # right-align to fixed width → no horizontal jitter
        printf -v fill  '%*s' "$filled"          ''; fill="${fill// /█}"
        printf -v empty '%*s' "$(( barw - filled ))" ''; empty="${empty// /░}"
        line="${AMBER}⏱  ${timestr} left${R}  ${DIM}▕${R}${ACC}${fill}${DIM}${empty}${R}${DIM}▏${R} ${B}${pct}%${R}"
        # Save cursor, jump below the scroll region, clear+paint the bar, restore
        # cursor so the streaming logs pick up exactly where they left off.
        printf '\e7\e[%d;1H\e[2K%s\e8' "$row" "$line"
        sleep 1
    done
}

# Idempotent: stop the bar loop, release the scroll region, wipe our chrome and
# restore the cursor. Safe to call from a trap and again sequentially.
#   _host_bar_cleanup <bar_pid> <rule_row>
_host_bar_cleanup() {
    local pid=$1 rule_row=$2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    printf '\e[r'                          # release scroll region (full screen)
    printf '\e[%d;1H\e[J' "$rule_row"      # erase the rule + bar lines
    printf '\e[?25h'                       # show cursor
}

do_host_launch() {
    ask_minutes
    banner "Launch host on $LEKIWI_HOST (robot_id=$ROBOT_ID, $(( CONNECTION_TIME / 60 )) min)"
    printf '  %s⚠ holds this terminal — run teleop/record in another. Ctrl+C or ./%s host-kill to stop.%s\n\n' "$AMBER" "$SELF" "$R"

    # No interactive TTY (or terminal too short to size) → plain stream, no bar.
    # SIGINT is left to the caller: the menu loop's no-op INT trap keeps the menu
    # alive on Ctrl+C; in direct mode Ctrl+C just ends the session.
    local size='' rows=0 cols=0
    if { [ -t 1 ] && [ -t 0 ]; } && size="$(stty size 2>/dev/null)"; then
        read -r rows cols <<< "$size"
    fi
    if ! { [ "${rows:-0}" -ge 4 ] && [ "${cols:-0}" -ge 24 ]; } 2>/dev/null; then
        _host_ssh
        return
    fi

    # Bar width is fixed up-front (from the max time string) so digit changes
    # like 100:00→99:59 don't make the bar jitter. Layout on the bottom row:
    #   "⏱  MM:SS left  ▕<bar>▏ NNN%"  →  14 fixed cells + time + pct + bar.
    local total=$CONNECTION_TIME start mm0 l_time barw ruleline bar_pid rc=0
    start=$(date +%s)
    mm0=$(( total / 60 ))
    l_time=$(( ${#mm0} + 3 ))               # "MM:SS" = digits(mm) + ":SS"
    barw=$(( cols - 15 - l_time - 4 ))      # 4 = widest pct "100%"; 15 = chrome + 1 margin
    [ "$barw" -lt 8 ]  && barw=8
    [ "$barw" -gt 64 ] && barw=64
    printf -v ruleline '%*s' "$(( cols - 1 ))" ''; ruleline="${ruleline// /━}"

    # Pin the bar: reserve the bottom 2 rows (rule + bar), confine logs above.
    printf '\e[?25l'                                                  # hide cursor
    printf '\e[%d;1H\e[J' "$(( rows - 1 ))"                           # clear chrome rows
    printf '\e[1;%dr' "$(( rows - 2 ))"                               # scroll region = top
    printf '\e[%d;1H%s%s%s' "$(( rows - 1 ))" "$BORD" "$ruleline" "$R"  # static rule
    printf '\e[%d;1H' "$(( rows - 2 ))"                               # cursor back in region

    # Note: resize (SIGWINCH) mid-session is not handled — barw/region are baked
    # in at launch, so a terminal resize leaves the bar misaligned until restart.
    _host_bar_loop "$start" "$total" "$rows" "$barw" "$l_time" & bar_pid=$!

    # Safety net for an unexpected local INT/TERM (terminal closed, kill): restore
    # the terminal. With `ssh -t`, Ctrl+C is delivered to the *remote* PTY, so this
    # trap normally never fires and the menu's own INT trap is preserved below.
    local _si _st
    _si="$(trap -p INT)"; _st="$(trap -p TERM)"
    trap '_host_bar_cleanup '"$bar_pid"' '"$(( rows - 1 ))" INT TERM

    _host_ssh || rc=$?                       # guarded so cleanup always runs (both modes)

    _host_bar_cleanup "$bar_pid" "$(( rows - 1 ))"
    eval "${_si:-trap - INT}"; eval "${_st:-trap - TERM}"
    return "$rc"
}

do_host_kill() {
    banner "Kill host on $LEKIWI_HOST (robot_id=$ROBOT_ID)"
    ssh -o ConnectTimeout=5 "${LEKIWI_HOST}" "
        PIDS=\$(pgrep -f 'python.*lekiwi_host.*--robot\.id=${ROBOT_ID}' || true)
        if [ -n \"\$PIDS\" ]; then
            echo \"Found processes: \$PIDS\"; echo \$PIDS | xargs -r kill -9
            echo '✅ Killed lekiwi_host for ROBOT_ID=${ROBOT_ID}'
        else echo 'ℹ️  No lekiwi_host processes for ROBOT_ID=${ROBOT_ID}'; fi
        ps aux | grep '[p]ython.*lekiwi_host.*robot\.id=${ROBOT_ID}' | awk '{print \$2}' | xargs -r kill -9 2>/dev/null || true
    " 2>&1 || {
        echo "⚠️  SSH failed; killing local SSH tunnels for this robot..."
        pkill -9 -f "ssh.*${LEKIWI_HOST}.*robot\.id=${ROBOT_ID}" 2>/dev/null || true
        echo "ℹ️  If still stuck, power-cycle the robot."
    }
    echo "${OKC}✓${R} cleanup complete for ROBOT_ID=${ROBOT_ID}"
}

# ─────────────────────────────────────────────────────────────────────────────
# LAPTOP-side lerobot CLIs (run in $LAPTOP_ENV, from project root)
# ─────────────────────────────────────────────────────────────────────────────
do_teleop() {
    ensure_local_env
    banner "Teleop — arm follows leader, keyboard drives base (Ctrl+C to stop)"
    printf '  %s⚠ the Pi host must already be running (host-launch, in another terminal).%s\n\n' "$AMBER" "$R"
    lerobot-teleoperate --config_path "$CFG_TELEOP" "$@"
}

# ── Yaml scalar lookups ─────────────────────────────────────────────────────
# _yaml_get <file> <anchored-key-regex> → first match's value (comment/space/
# quote-stripped) or empty. The regex anchors the expected nesting depth so a
# same-named key inside some other block can't be grabbed (`root:`/`repo_id:`
# sit one indent under `dataset:`, `task:` is top-level). Stays exit-0 so
# `set -e`/`pipefail` can't trip callers — they run both under `|| true`
# (menu) and bare (direct CLI).
_yaml_get() {
    local line v
    line="$(grep -E "$2" "$1" 2>/dev/null | head -1 || true)"
    v="${line#*:}"; v="${v%%#*}"                                 # after the key, drop comment
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"   # trim space
    v="${v#[\"\']}"; v="${v%[\"\']}"                             # strip surrounding quotes
    printf '%s\n' "$v"
    return 0
}

# Where will this record land? A --dataset.root= override on the args wins;
# otherwise parse `root:` from the yaml; otherwise the documented default. The
# path is left as-is (relative resolves against cwd, which is WORK_DIR).
record_root() {
    local a r
    for a in "$@"; do case "$a" in --dataset.root=*) printf '%s\n' "${a#--dataset.root=}"; return 0 ;; esac; done
    r="$(_yaml_get "$CFG_RECORD" '^[[:space:]]+root:')"
    printf '%s\n' "${r:-datasets/lekiwi_dataset}"
}
# The dataset repo_id (HF `namespace/name`) parsed from the record yaml; used by
# `view` to point lerobot-dataset-viz at the right dataset.
dataset_repo_id() {
    local r
    r="$(_yaml_get "$CFG_RECORD" '^[[:space:]]+repo_id:')"
    printf '%s\n' "${r:-local/lekiwi_dataset}"
}
# Trigger on a NON-EMPTY directory, not a valid info.json: a crashed/partial
# recording leaves a dir lerobot still refuses to overwrite, and that's exactly
# when Delete is most useful.
dataset_present() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null || true)" ]; }
# Best-effort episode count; "?" when meta/info.json is missing or unparseable.
# (`// "?"` covers a missing key in-band; `|| true` covers a missing file/jq.)
dataset_episodes() {
    local n; n="$(jq -r '.total_episodes // "?"' "$1/meta/info.json" 2>/dev/null || true)"
    printf '%s\n' "${n:-?}"
}
args_have_resume() { local a; for a in "$@"; do case "$a" in --resume|--resume=*) return 0 ;; esac; done; return 1; }

# Read one keypress into the global KEY, decoding ESC sequences (arrow keys) by
# grabbing the 2-byte tail with a short timeout. EOF → KEY=q so input loops exit.
# Shared by choose_one, the eval form, and the main menu.
KEY=''
read_key() {
    local rest
    IFS= read -rsn1 KEY || { KEY='q'; return 0; }
    if [ "$KEY" = $'\e' ]; then IFS= read -rsn2 -t 0.01 rest || rest=''; KEY+="$rest"; fi
}

# Discard queued type-ahead before a line-oriented `read -r` prompt. Two reasons:
# stale keystrokes shouldn't leak into a text field, and — the subtle one — bash's
# plain `read -r` does a BUFFERED read; bytes queued while the tty was still raw
# (mid read_key) have no line boundaries, so the buffered read can swallow keys
# typed ahead of the prompt, and bash can't push them back onto a tty — they're
# silently lost. Draining with unbuffered -n1 reads first avoids both.
flush_typeahead() { local _j; while IFS= read -rsn1 -t 0.01 _j; do :; done; return 0; }

# Generic arrow-key single-choice picker (same key handling as the main menu).
#   choose_one "title" "opt0" "opt1" ...  -> sets CHOICE_IDX (0-based)
#   returns 1 (and CHOICE_IDX=-1) on cancel via q/Esc or no TTY.
CHOICE_IDX=-1
choose_one() {
    { [ -t 0 ] && [ -t 1 ]; } || { CHOICE_IDX=-1; return 1; }
    local title="$1"; shift
    local opts=("$@") n=$# sel=0 key i
    printf '\e[?25l'
    while true; do
        printf '\e[H\e[2J\n'
        printf '  %s%s◆ LEKIWI%s  %s%s%s\n' "$B" "$ACC" "$R" "$DIM" "${PICKER_LABEL:-record}" "$R"
        printf '  %s%s%s\n\n' "$ACC" "$RULE_HEAVY" "$R"
        printf '  %s%s%s\n\n' "$B" "$title" "$R"
        for i in $(seq 0 $((n-1))); do
            if [ "$i" = "$sel" ]; then printf '   %s❯%s  %s%s%s\n' "$ACC" "$R" "$B$ACC" "${opts[$i]}" "$R"
            else printf '      %s%s%s\n' "$DIM" "${opts[$i]}" "$R"; fi
        done
        printf '\n  %s%s%s\n' "$BORD" "$RULE_LIGHT" "$R"
        printf '  %s↑↓%s/%sjk%s move   %s⏎%s select   %sq%s cancel\n' "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$R$DIM" "$ACC" "$R"
        read_key; key=$KEY
        case "$key" in
            $'\e[A'|k|K)     sel=$(( (sel - 1 + n) % n )) ;;
            $'\e[B'|j|J)     sel=$(( (sel + 1) % n )) ;;
            ''|$'\n'|$'\r')  CHOICE_IDX=$sel; printf '\e[?25h'; return 0 ;;
            q|Q|$'\e')       CHOICE_IDX=-1; printf '\e[?25h'; return 1 ;;
        esac
    done
}

# ── Interactive directory browser (pure ANSI, read_key-driven) ──────────────
# browse_dir <start-dir> <title>  → BROWSE_RESULT (absolute dir); returns 1 on
# cancel or no TTY. ⏎/→ descends into the highlighted subdir, ← goes up, ⏎ on
# the "✓ use this directory" row picks the CURRENT dir, t = type a path to jump
# there, q/Esc cancels. Dot-dirs are hidden from the list (type a path to reach
# one). The listing is re-scanned per frame, so it follows the live filesystem.
BROWSE_RESULT=''
browse_dir() {
    { [ -t 0 ] && [ -t 1 ]; } || { BROWSE_RESULT=''; return 1; }
    local cur="$1" title="$2" sel=0 i n key win=12 top end label ans note='' above below hint
    [ -d "$cur" ] || cur="$WORK_DIR"
    cur="$(cd "$cur" 2>/dev/null && pwd || printf '%s\n' "$WORK_DIR")"
    BROWSE_RESULT=''
    printf '\e[?25l'
    while true; do
        local subdirs=() d
        while IFS= read -r d; do subdirs+=("$d"); done \
            < <(find "$cur" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' 2>/dev/null | sort)
        n=$(( ${#subdirs[@]} + 1 ))                  # row 0 = "use this directory"
        [ "$sel" -ge "$n" ] && sel=$(( n - 1 )); [ "$sel" -lt 0 ] && sel=0
        printf '\e[H\e[2J\n'
        printf '  %s%s◆ LEKIWI%s  %sbrowse%s\n' "$B" "$ACC" "$R" "$DIM" "$R"
        printf '  %s%s%s\n\n' "$ACC" "$RULE_HEAVY" "$R"
        printf '  %s%s%s\n' "$B" "$title" "$R"
        printf '  %s%s%s\n\n' "$AMBER" "${cur/#$HOME/\~}" "$R"
        top=0
        if [ "$n" -gt "$win" ]; then
            top=$(( sel - win/2 )); [ "$top" -lt 0 ] && top=0
            [ "$top" -gt $(( n - win )) ] && top=$(( n - win ))
        fi
        end=$(( top + win )); [ "$end" -gt "$n" ] && end=$n
        for (( i=top; i<end; i++ )); do
            if [ "$i" = 0 ]; then label="✓ use this directory"
            else label="${subdirs[$((i-1))]}/"; fi
            if [ "$i" = "$sel" ]; then printf '   %s❯%s  %s%s%s\n' "$ACC" "$R" "$B$ACC" "$label" "$R"
            else printf '      %s%s%s\n' "$DIM" "$label" "$R"; fi
        done
        above=$top; below=$(( n - end )); hint=''
        [ "$above" -gt 0 ] && hint="▴ $above above   "
        [ "$below" -gt 0 ] && hint="${hint}▾ $below more"
        [ -n "$hint" ] && printf '      %s%s%s\n' "$DIM" "$hint" "$R"
        printf '\n  %s%s%s\n' "$BORD" "$RULE_LIGHT" "$R"
        [ -n "$note" ] && printf '  %s%s%s\n' "$AMBER" "$note" "$R"
        printf '  %s↑↓%s move   %s→⏎%s enter dir   %s←%s up   %s⏎%s on ✓ pick   %st%s type path   %sq%s cancel\n' \
            "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$R"
        note=''
        read_key; key=$KEY
        case "$key" in
            $'\e[A'|k|K) sel=$(( (sel - 1 + n) % n )) ;;
            $'\e[B'|j|J) sel=$(( (sel + 1) % n )) ;;
            $'\e[D'|h|H) cur="$(dirname "$cur")"; sel=0 ;;
            $'\e[C'|l|L)
                [ "$sel" -gt 0 ] && { cur="$(cd "$cur/${subdirs[$((sel-1))]}" 2>/dev/null && pwd || printf '%s\n' "$cur")"; sel=0; } ;;
            ''|$'\n'|$'\r')
                if [ "$sel" = 0 ]; then BROWSE_RESULT="$cur"; printf '\e[?25h'; return 0
                else cur="$(cd "$cur/${subdirs[$((sel-1))]}" 2>/dev/null && pwd || printf '%s\n' "$cur")"; sel=0; fi ;;
            t|T|m|M)
                printf '\e[?25h\n  %sgo to path%s %s[%s]%s ' "$ACC" "$R" "$DIM" "${cur/#$HOME/\~}" "$R"
                flush_typeahead; read -r ans || ans=''
                ans="${ans/#\~/$HOME}"
                if [ -z "$ans" ]; then :
                elif [ -d "$ans" ]; then cur="$(cd "$ans" && pwd)"; sel=0
                else note="✗ not a directory: $ans"; fi
                printf '\e[?25l' ;;
            q|Q|$'\e') printf '\e[?25h'; BROWSE_RESULT=''; return 1 ;;
        esac
    done
}

do_record() {
    local root resume_flag='' eps='' label nep ans
    PICKER_LABEL="record"
    root="$(record_root "$@")"

    # If a dataset already lives there and --resume wasn't passed, let the user
    # Resume / Delete / Cancel before paying the conda-env activation cost.
    if dataset_present "$root" && ! args_have_resume "$@"; then
        nep="$(dataset_episodes "$root")"
        if { [ -t 0 ] && [ -t 1 ]; }; then
            if choose_one "Dataset already exists at \"$root\" (${nep} episodes recorded)." \
                "Resume   — keep it and record MORE episodes into it" \
                "Delete   — permanently wipe it and start fresh" \
                "Cancel   — go back, change nothing"; then
                case "$CHOICE_IDX" in
                    0) resume_flag='--resume=true' ;;
                    1) printf '\e[H\e[2J\n'
                       printf '  %s%s⚠ DELETE%s  %s%s%s %s(%s episodes)%s\n\n' "$B" "$ERRC" "$R" "$AMBER" "$root" "$R" "$DIM" "$nep" "$R"
                       printf '  This cannot be undone. Type %sdelete%s to confirm (anything else cancels): ' "$ERRC" "$R"
                       flush_typeahead; read -r ans || ans=''
                       if [ "$ans" = "delete" ]; then
                           if [ -z "$root" ] || [ "$root" = "/" ] || [ "$root" = "$HOME" ]; then
                               echo "${ERRC}✗${R} refusing to delete unsafe path '$root'." >&2; return 1
                           fi
                           rm -rf -- "$root" && printf '  %s✓ removed %s%s\n' "$OKC" "$root" "$R"
                       else
                           printf '  %s✗ not deleted — dataset kept, nothing recorded.%s\n' "$DIM" "$R"; return 0
                       fi ;;
                    *) printf '  %scancelled — nothing recorded.%s\n' "$DIM" "$R"; return 0 ;;
                esac
            else
                printf '  %scancelled — nothing recorded.%s\n' "$DIM" "$R"; return 0
            fi
        else
            echo "${ERRC}✗${R} dataset already exists at '$root' (${nep} episodes)." >&2
            echo "  Re-run with --resume=true to append, or delete the folder to start fresh." >&2
            return 1
        fi
    fi

    ensure_local_env
    if [ -t 0 ]; then
        label='Number of episodes'; [ -n "$resume_flag" ] && label='Number of ADDITIONAL episodes'
        printf '  %s%s%s %s[blank = config default]%s ' "$ACC" "$label" "$R" "$DIM" "$R"; flush_typeahead; read -r eps || eps=''
    fi
    banner "Record dataset → $root${resume_flag:+  (resume)}"
    printf '  %s⚠ the Pi host must already be running.%s\n\n' "$AMBER" "$R"
    local args=(--config_path "$CFG_RECORD")
    [ -n "$resume_flag" ] && args+=("$resume_flag")
    [ -n "$eps" ] && args+=(--dataset.num_episodes="$eps")
    lerobot-record "${args[@]}" "$@"
}

do_replay() {
    ensure_local_env
    local ep='0'
    if [ -t 0 ]; then printf '  %sEpisode index to replay%s %s[0]%s ' "$ACC" "$R" "$DIM" "$R"; flush_typeahead; read -r ep || ep='0'; ep="${ep:-0}"; fi
    banner "Replay episode $ep"
    printf '  %s⚠ the Pi host must already be running.%s\n\n' "$AMBER" "$R"
    lerobot-replay --config_path "$CFG_REPLAY" --dataset.episode="$ep" "$@"
}

# View a recorded episode in Rerun (camera streams + state/action signals) via
# lerobot-dataset-viz. Reads the LOCAL dataset → the Pi host is NOT required.
# repo_id/root come from the record yaml; --dataset.root= on the args overrides root.
# Extra flags pass through (e.g. --mode distant, --save 1 --output-dir DIR).
do_view() {
    local root repo_id ep='0' nep hint
    root="$(record_root "$@")"
    repo_id="$(dataset_repo_id)"
    if ! dataset_present "$root"; then
        echo "${ERRC}✗${R} no dataset at '$root' — record some episodes first (or pass --dataset.root=…)." >&2
        return 1
    fi
    nep="$(dataset_episodes "$root")"

    ensure_local_env
    if [ -t 0 ]; then
        hint='[0]'; [ "$nep" != "?" ] && hint="[0–$(( nep - 1 ))]"
        printf '  %sEpisode index to view%s %s%s%s ' "$ACC" "$R" "$DIM" "$hint" "$R"
        flush_typeahead; read -r ep || ep='0'; ep="${ep:-0}"
        [[ "$ep" =~ ^[0-9]+$ ]] || { printf '  %sinvalid — using 0%s\n' "$DIM" "$R"; ep=0; }
    fi
    banner "View dataset episode $ep — Rerun"
    printf '  %sℹ reads local data; the Pi host is NOT required.%s\n' "$DIM" "$R"
    printf '  %sdataset: %s%s%s %s(%s episodes)%s\n\n' "$DIM" "$R$AMBER" "$root" "$R" "$DIM" "$nep" "$R"
    lerobot-dataset-viz --repo-id "$repo_id" --root "$root" --episode-index "$ep" "$@"
}

# Find loadable checkpoints under $POLICY_ROOT, newest first → DISCOVERED_POLICIES.
# A dir counts only if it holds config.json + model.safetensors (what from_pretrained
# needs locally). Stays exit-0 so `set -e` can't trip the caller.
DISCOVERED_POLICIES=()
EVAL_DEFAULT_ABS=''   # resolve_policy result for the current eval run ("← default" marker)
discover_policies() {
    DISCOVERED_POLICIES=()
    [ -d "$POLICY_ROOT" ] || return 0
    local d
    while IFS= read -r d; do
        [ -f "$d/config.json" ] && [ -f "$d/model.safetensors" ] && DISCOVERED_POLICIES+=("$d")
    done < <(find "$POLICY_ROOT" -type d -name pretrained_model -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    return 0
}

# Resolve POLICY_PATH to something lerobot can load. POLICY_PATH is interpreted
# as: empty → newest checkpoint discovered under POLICY_ROOT ("auto"); relative
# path that exists under POLICY_ROOT → prefixed with it; anything else (absolute
# path, HF repo id) → as-is. Echoes the result ('' if auto finds nothing).
resolve_policy() {
    local p="$POLICY_PATH"
    if [ -z "$p" ]; then
        discover_policies
        [ "${#DISCOVERED_POLICIES[@]}" -gt 0 ] && p="${DISCOVERED_POLICIES[0]}"
    elif [ "${p#/}" = "$p" ] && [ -d "$POLICY_ROOT/$p" ]; then
        p="$POLICY_ROOT/$p"
    fi
    printf '%s\n' "$p"
    return 0
}

# The language instruction the rollout will actually send (top-level `task:` in
# the yaml). "?" if absent. SmolVLA is language-conditioned, so showing this lets
# the user catch a policy↔task mismatch before launching.
rollout_task() {
    local t
    t="$(_yaml_get "$CFG_ROLLOUT" '^task:')"
    printf '%s\n' "${t:-?}"
}

# Render one field row of the eval form.  Focused row gets a ❯ pointer + accent
# label; others are dim.  Value is shown in accent, the hint trailing in dim.
#   _eval_row <focused-field-id> <this-field-id> <label> <value> <hint>
_eval_row() {
    local cur="$1" id="$2" label="$3" value="$4" hint="$5" ptr lblc
    if [ "$cur" = "$id" ]; then ptr="${ACC}❯${R}"; lblc="${B}${ACC}"; else ptr=' '; lblc="$DIM"; fi
    printf '   %s  %s%-13s%s  %s%s%s   %s%s%s\n' "$ptr" "$lblc" "$label" "$R" "$ACC" "$value" "$R" "$DIM" "$hint" "$R"
}

# Render the Policy field. Collapsed (not focused) → one value line. Focused
# (expanded=1) → a scrolling 5-row list of discovered checkpoints + a "Custom"
# row, windowed around <psel> with ▴/▾ overflow hints. Reads DISCOVERED_POLICIES,
# POLICY_ROOT, EVAL_DEFAULT_ABS (globals).
#   _eval_policy_block <expanded:0|1> <psel> <pol_idx> <selected-policy>
_eval_policy_block() {
    local expanded="$1" psel="$2" pol_idx="$3" sel="$4"
    local n=${#DISCOVERED_POLICIES[@]} m win=5 i top end label marker disp above below hint
    m=$(( n + 1 ))                                  # +1 for the Custom row
    if [ "$expanded" != 1 ]; then
        if [ "$pol_idx" -ge 0 ]; then disp="${DISCOVERED_POLICIES[$pol_idx]#"$POLICY_ROOT"/}"; else disp="${sel/#$HOME/\~}"; fi
        [ -n "$sel" ] && [ "$sel" = "$EVAL_DEFAULT_ABS" ] && marker="← default" || marker=""
        _eval_row "" policy "Policy" "$disp" "$marker"
        return 0
    fi
    printf '   %s❯%s  %s%sPolicy%s\n' "$ACC" "$R" "$B" "$ACC" "$R"
    top=0
    if [ "$m" -gt "$win" ]; then
        top=$(( psel - win/2 ))
        [ "$top" -lt 0 ] && top=0
        [ "$top" -gt $(( m - win )) ] && top=$(( m - win ))
    fi
    end=$(( top + win )); [ "$end" -gt "$m" ] && end=$m
    for (( i=top; i<end; i++ )); do
        if [ "$i" -lt "$n" ]; then
            label="${DISCOVERED_POLICIES[$i]#"$POLICY_ROOT"/}"
            [ "${DISCOVERED_POLICIES[$i]}" = "$EVAL_DEFAULT_ABS" ] && marker="  ${DIM}← default${R}" || marker=""
        else
            label="Custom path / HF repo…"; marker=""
        fi
        if [ "$i" = "$psel" ]; then printf '       %s❯%s %s%s%s%s\n' "$ACC" "$R" "$B$ACC" "$label" "$R" "$marker"
        else printf '         %s%s%s%s\n' "$DIM" "$label" "$R" "$marker"; fi
    done
    above=$top; below=$(( m - end )); hint=""
    [ "$above" -gt 0 ] && hint="▴ $above above   "
    [ "$below" -gt 0 ] && hint="${hint}▾ $below more"
    printf '       %s%s%s\n' "$DIM" "$hint" "$R"
    return 0
}

# Paint one full frame of the eval configuration form.  Snapshot-testable via
# LEKIWI_EVAL_RENDER_TEST (it seeds DISCOVERED_POLICIES first).
#   _eval_draw <cur> <psel> <pol_idx> <policy> <backend> <eh> <dur> <show> <err>
_eval_draw() {
    local cur="$1" psel="$2" pol_idx="$3" policy="$4" backend="$5" eh="$6" dur="$7" show="$8" err="$9"
    local dnum dur_disp bk_hint pexp show_disp
    dnum=$(( 10#${dur:-0} ))
    [ "$dnum" -gt 0 ] && dur_disp="${dnum}s" || dur_disp="config default"
    [ "$backend" = rtc ] && bk_hint="Real-Time Chunking (smoother for slow VLAs)" || bk_hint="one policy forward per control tick"
    [ "$show" = 1 ] && show_disp="‹ on ›" || show_disp="‹ off ›"
    [ "$cur" = policy ] && pexp=1 || pexp=0

    printf '\e[H\e[2J\n'
    printf '  %s%s◆ LEKIWI%s  %seval%s\n' "$B" "$ACC" "$R" "$DIM" "$R"
    printf '  %s%s%s\n\n' "$ACC" "$RULE_HEAVY" "$R"
    printf '  %sConfigure rollout%s\n\n' "$B" "$R"

    _eval_policy_block "$pexp" "$psel" "$pol_idx" "$policy"
    _eval_row "$cur" backend  "Backend"      "‹ $backend ›"  "$bk_hint"
    if [ "$backend" = rtc ]; then
        _eval_row "$cur" exec  "Exec horizon" "$eh"          "rtc blend window — keep above the inference delay"
    else
        printf '      %sExec horizon    —             (rtc only)%s\n' "$DIM" "$R"
    fi
    _eval_row "$cur" duration "Duration"     "$dur_disp"     "seconds; 0 = config default"
    _eval_row "$cur" display  "Display"      "$show_disp"    "Rerun live view (off = headless, lower CPU)"

    printf '\n'
    if [ "$cur" = start ]; then printf '   %s❯%s  %s▶ Start eval%s\n' "$ACC" "$R" "$B$ACC" "$R"
    else printf '      %s%s▶ Start eval%s\n' "$ACC" "$B" "$R"; fi
    printf '\n'
    [ -n "$err" ] && printf '  %s✗ %s%s\n\n' "$ERRC" "$err" "$R"
    printf '  %s%s%s\n' "$BORD" "$RULE_LIGHT" "$R"
    if [ "$cur" = policy ]; then
        printf '  %s↑↓%s pick   %s⏎%s confirm → next   %sq%s cancel\n' "$ACC" "$DIM" "$ACC" "$R$DIM" "$ACC" "$R"
    else
        printf '  %s↑↓%s/%sjk%s move   %s←→%s change   %s⏎%s pick / run   %sq%s cancel\n' \
            "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$R$DIM" "$ACC" "$R"
    fi
}

# Validate the chosen policy, then run lerobot-rollout. Shared by the TTY form and
# the headless path. Args: <policy> <backend> <eh> <dur> [extra CLI args…].
# A local dir must hold config.json+model.safetensors; a bare repo id passes through.
_eval_launch() {
    local policy="$1" backend="$2" eh="$3" dur="$4" show="$5"; shift 5
    if [ -z "$policy" ]; then
        echo "${ERRC}✗${R} no policy: POLICY_PATH is empty (auto) and no checkpoint found under '$POLICY_ROOT'." >&2
        return 1
    fi
    if [ -d "$policy" ]; then
        if [ ! -f "$policy/config.json" ] || [ ! -f "$policy/model.safetensors" ]; then
            echo "${ERRC}✗${R} '$policy' is not a valid checkpoint" >&2
            echo "  expected config.json + model.safetensors (e.g. .../checkpoints/last/pretrained_model)." >&2
            return 1
        fi
    elif [ -e "$policy" ]; then
        echo "${ERRC}✗${R} '$policy' exists but is not a directory." >&2; return 1
    else
        printf '  %sℹ '\''%s'\'' is not a local dir — treating it as a Hugging Face repo id.%s\n' "$DIM" "$policy" "$R"
    fi

    # Device auto-detect. lerobot resolves device as: explicit --device (if available)
    # → checkpoint config.json device (post_init swaps it if unavailable) → auto
    # (cuda → mps → cpu). When a GPU is present we pass --device=cuda explicitly so
    # even a checkpoint saved with device=cpu runs on the GPU; a user --device=…
    # in the extra args comes later on the CLI and still wins (draccus last-wins).
    local ckpt_dev='' dev_note
    [ -d "$policy" ] && ckpt_dev="$(jq -r '.device // empty' "$policy/config.json" 2>/dev/null || true)"
    if [ -n "$GPU_NAME" ]; then
        dev_note="${OKC}cuda${R} ${DIM}(GPU present: ${GPU_NAME} — lerobot falls back to cpu if torch can't use it)${R}"
    elif [ "$ckpt_dev" = cuda ] || [ -z "$ckpt_dev" ]; then
        dev_note="${AMBER}no NVIDIA GPU detected — lerobot will auto-select (likely cpu, slow)${R}"
    else
        dev_note="${DIM}${ckpt_dev} (from checkpoint config)${R}"
    fi

    ensure_local_env
    local ehsuf='' disp_word=off disp_flag=false
    [ "$backend" = rtc ] && ehsuf=" · eh=$eh"
    [ "$show" = 1 ] && { disp_word=on; disp_flag=true; }
    banner "Eval (rollout) — policy drives · infer=$backend$ehsuf · rerun=$disp_word"
    printf '  %spolicy: %s%s%s\n' "$DIM" "$R$AMBER" "${policy/#$HOME/\~}" "$R"
    printf '  %sdevice: %s\n' "$DIM" "$dev_note"
    printf '  %s⚠ the Pi host must already be running (host-launch, in another terminal).%s\n' "$AMBER" "$R"
    printf '  %sℹ task sent to policy: %s"%s"%s  %s(edit task: in %s if it doesn'\''t match training)%s\n\n' \
        "$DIM" "$R$ACC" "$(rollout_task)" "$R" "$DIM" "$CFG_ROLLOUT" "$R"

    local args=(--config_path "$CFG_ROLLOUT" --policy.path="$policy" --inference.type="$backend" --display_data="$disp_flag")
    [ -n "$GPU_NAME" ] && args+=(--device=cuda)
    [ "$backend" = rtc ] && args+=(--inference.rtc.execution_horizon="$eh")
    [ -n "$dur" ] && [ "$dur" != 0 ] && args+=(--duration="$dur")
    lerobot-rollout "${args[@]}" "$@"
}

do_eval() {
    # Run a trained policy on the robot and WATCH it (Rerun) — base strategy, no
    # recording. Uses lerobot-rollout (NOT lerobot-eval, which is sim-only).
    # TTY → one-screen config form; non-TTY → headless with env defaults.
    local policy backend="$INFERENCE" eh="$EXECUTION_HORIZON" dur='' show=0
    policy="$(resolve_policy)"            # POLICY_PATH: auto/relative/absolute → loadable
    EVAL_DEFAULT_ABS="$policy"            # what the policy list marks as "← default"
    case "${DISPLAY_DATA,,}" in 1|true|yes|on) show=1 ;; esac   # non-TTY default (else off)
    PICKER_LABEL="eval"

    # If the configured POLICY_PATH is a local path that no longer exists (e.g. a
    # deleted training run), fall back to the newest discovered checkpoint instead
    # of mis-treating the dead path as a Hugging Face repo id. Bare repo ids
    # (namespace/name) don't match the path patterns and pass through untouched.
    case "$policy" in
        /*|./*) if [ ! -d "$policy" ]; then
                    discover_policies
                    if [ "${#DISCOVERED_POLICIES[@]}" -gt 0 ]; then
                        printf '  %sℹ configured POLICY_PATH is gone (%s) — defaulting to newest checkpoint: %s%s\n' \
                            "$DIM" "${policy/#$HOME/\~}" "${DISCOVERED_POLICIES[0]#"$POLICY_ROOT"/}" "$R"
                        policy="${DISCOVERED_POLICIES[0]}"; EVAL_DEFAULT_ABS="$policy"
                    fi
                fi ;;
    esac

    if [ -z "$policy" ] && ! { [ -t 0 ] && [ -t 1 ]; }; then
        echo "${ERRC}✗${R} no policy: POLICY_PATH is empty (auto) and no checkpoint found under '$POLICY_ROOT'." >&2
        return 1
    fi

    if ! { [ -t 0 ] && [ -t 1 ]; }; then
        _eval_launch "$policy" "$backend" "$eh" "$dur" "$show" "$@"
        return
    fi

    # Discover checkpoints for the Policy field. When focused, Policy expands into a
    # scrolling list (↑↓ pick, ⏎ confirm → next field). psel = highlighted list row;
    # the list is the n discovered paths plus a final "Custom" row (index n).
    discover_policies
    local n=${#DISCOVERED_POLICIES[@]} i pol_idx=-1 m
    if [ "$n" -gt 0 ]; then
        for (( i=0; i<n; i++ )); do [ "${DISCOVERED_POLICIES[$i]}" = "$policy" ] && pol_idx=$i || true; done
    fi
    m=$(( n + 1 ))
    # Open the list on the configured default if it still exists; otherwise the
    # newest discovered checkpoint (index 0), or the Custom row when none were found.
    local psel=$(( pol_idx >= 0 ? pol_idx : 0 ))

    local fpos=0 err='' key cur ans focus fcount

    # The form loop steers control flow with arithmetic/test exit codes, which
    # fights errexit — disable it for the loop only, then restore the prior state.
    local _errexit=''; case $- in *e*) _errexit=1 ;; esac
    set +e
    # Direct (non-menu) mode has no global INT trap, so Ctrl+C mid-form would leave
    # the cursor hidden — restore it on the way out. (Menu mode keeps its own trap.)
    [ -z "${IN_MENU:-}" ] && trap 'printf "\e[?25h\e[0m"; exit 130' INT

    printf '\e[?25l'
    while true; do
        focus=(policy backend); [ "$backend" = rtc ] && focus+=(exec); focus+=(duration display start)
        fcount=${#focus[@]}
        [ "$fpos" -ge "$fcount" ] && fpos=$((fcount-1)); [ "$fpos" -lt 0 ] && fpos=0
        cur="${focus[$fpos]}"

        _eval_draw "$cur" "$psel" "$pol_idx" "$policy" "$backend" "$eh" "$dur" "$show" "$err"

        read_key; key=$KEY
        err=''
        case "$key" in
            $'\e[A'|k|K)   # in the policy list ↑↓ scroll the list; elsewhere move fields
                if [ "$cur" = policy ]; then psel=$(( (psel - 1 + m) % m ))
                else fpos=$(( (fpos - 1 + fcount) % fcount )); fi ;;
            $'\e[B'|j|J)
                if [ "$cur" = policy ]; then psel=$(( (psel + 1) % m ))
                else fpos=$(( (fpos + 1) % fcount )); fi ;;
            $'\e[D'|h|H)   # ← decrease (numeric / toggle); policy has no left/right
                case "$cur" in
                    backend)  [ "$backend" = rtc ] && backend=sync || backend=rtc ;;
                    exec)     eh=$(( eh - 1 )); [ "$eh" -lt 1 ] && eh=1 ;;
                    duration) dur=$(( 10#${dur:-0} - 5 )); [ "$dur" -lt 0 ] && dur=0 ;;
                    display)  [ "$show" = 1 ] && show=0 || show=1 ;;
                esac ;;
            $'\e[C'|l|L)   # → increase / toggle
                case "$cur" in
                    backend)  [ "$backend" = rtc ] && backend=sync || backend=rtc ;;
                    exec)     eh=$(( eh + 1 )) ;;
                    duration) dur=$(( 10#${dur:-0} + 5 )) ;;
                    display)  [ "$show" = 1 ] && show=0 || show=1 ;;
                esac ;;
            [0-9])
                case "$cur" in
                    exec)     eh="${eh}${key}"; [ "${#eh}" -gt 4 ] && eh="${eh:0:4}" ;;
                    duration) dur="${dur}${key}"; [ "${#dur}" -gt 5 ] && dur="${dur:0:5}" ;;
                esac ;;
            $'\x7f'|$'\b')
                case "$cur" in exec) eh="${eh%?}" ;; duration) dur="${dur%?}" ;; esac ;;
            ''|$'\n'|$'\r')
                case "$cur" in
                    policy)   # confirm the highlighted list row, then advance to Backend
                        if [ "$psel" -lt "$n" ]; then
                            pol_idx=$psel; policy="${DISCOVERED_POLICIES[$psel]}"; fpos=1
                        else
                            printf '\e[?25h'
                            printf '  %sPolicy path or HF repo id%s %s[%s]%s ' "$ACC" "$R" "$DIM" "${policy/#$HOME/\~}" "$R"
                            flush_typeahead; read -r ans || ans=''; policy="${ans:-$policy}"
                            policy="${policy/#\~/$HOME}"   # relative input resolves under POLICY_ROOT
                            [ "${policy#/}" = "$policy" ] && [ -d "$POLICY_ROOT/$policy" ] && policy="$POLICY_ROOT/$policy"
                            pol_idx=-1
                            for (( i=0; i<n; i++ )); do [ "${DISCOVERED_POLICIES[$i]}" = "$policy" ] && pol_idx=$i; done
                            psel=$(( pol_idx >= 0 ? pol_idx : n ))
                            printf '\e[?25l'; fpos=1
                        fi ;;
                    backend)  [ "$backend" = rtc ] && backend=sync || backend=rtc ;;
                    display)  [ "$show" = 1 ] && show=0 || show=1 ;;
                    exec|duration) fpos=$(( (fpos + 1) % fcount )) ;;
                    start)
                        if [ -d "$policy" ]; then
                            if [ ! -f "$policy/config.json" ] || [ ! -f "$policy/model.safetensors" ]; then
                                err="not a valid checkpoint (need config.json + model.safetensors)"; continue
                            fi
                        elif [ -e "$policy" ]; then
                            err="path exists but is not a directory"; continue
                        fi
                        break ;;
                esac ;;
            q|Q|$'\e')
                printf '\e[?25h'; printf '  %scancelled — nothing evaluated.%s\n' "$DIM" "$R"
                [ -z "${IN_MENU:-}" ] && trap - INT
                [ -n "$_errexit" ] && set -e
                return 0 ;;
        esac
    done
    printf '\e[?25h'
    [ -z "${IN_MENU:-}" ] && trap - INT
    [ -n "$_errexit" ] && set -e

    local eh_final dur_final
    eh_final=$(( 10#${eh:-0} )); [ "$eh_final" -lt 1 ] && eh_final="$EXECUTION_HORIZON"
    dur_final=$(( 10#${dur:-0} ))
    _eval_launch "$policy" "$backend" "$eh_final" "$dur_final" "$show" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# SETTINGS — interactive editor for CONFIG_SPEC → lekiwi.conf
# ─────────────────────────────────────────────────────────────────────────────
# Like _eval_row but with a 17-wide label column (config keys are longer than the
# eval form's field names — EXECUTION_HORIZON alone is 17 chars).
#   _settings_row <focused:0|1> <label> <value> <hint>
_settings_row() {
    local foc="$1" label="$2" value="$3" hint="$4" ptr lblc
    if [ "$foc" = 1 ]; then ptr="${ACC}❯${R}"; lblc="${B}${ACC}"; else ptr=' '; lblc="$DIM"; fi
    printf '   %s  %s%-17s%s  %s%s%s   %s%s%s\n' "$ptr" "$lblc" "$label" "$R" "$ACC" "$value" "$R" "$DIM" "$hint" "$R"
}

# Advance S_VAL[<key>] through its enum options (kind = enum:a,b[,…]), wrapping.
# <dir> = 1/-1. An unknown/legacy current value counts as the first option.
_settings_cycle_enum() {
    local key="$1" kind="$2" dir="${3:-1}" opts i n cur=0
    IFS=',' read -ra opts <<< "${kind#enum:}"
    n=${#opts[@]}
    for (( i=0; i<n; i++ )); do [ "${opts[$i]}" = "${S_VAL[$key]}" ] && cur=$i; done
    S_VAL[$key]="${opts[$(( (cur + dir + n) % n ))]}"
    return 0
}

# Paint one frame of the settings form. Fields come from CONFIG_SPEC, values from
# S_VAL (the unsaved working copy); env-overridden keys get a provenance tag.
# Snapshot-testable via LEKIWI_SETTINGS_RENDER_TEST (errexit-safe — it runs there
# outside the form's set +e island).
#   _settings_draw <focused-idx (n = Save row)> <msg> <dirty:0|1>
_settings_draw() {
    local cur="$1" msg="$2" dirty="$3"
    local i entry key kind hint val disp prov mark='' n=${#CONFIG_SPEC[@]}
    [ "$dirty" = 1 ] && mark="  ${AMBER}● unsaved${R}"
    printf '\e[H\e[2J\n'
    printf '  %s%s◆ LEKIWI%s  %ssettings%s%s\n' "$B" "$ACC" "$R" "$DIM" "$R" "$mark"
    printf '  %s%s%s\n\n' "$ACC" "$RULE_HEAVY" "$R"
    printf '  %sEdit config%s  %s→ %s · env overrides win until unset%s\n\n' \
        "$B" "$R" "$DIM" "${CONF_FILE/#$HOME/\~}" "$R"
    for (( i=0; i<n; i++ )); do
        IFS='|' read -r key kind hint <<< "${CONFIG_SPEC[$i]}"
        val="${S_VAL[$key]}"
        case "$kind" in
            enum:*) [ -z "$val" ] && { val="${kind#enum:}"; val="${val%%,*}"; }   # legacy empty → first option
                    disp="‹ $val ›" ;;
            *)      disp="${val/#$HOME/\~}"
                    if [ -z "$disp" ]; then
                        [ "$key" = POLICY_PATH ] && disp='auto (newest under POLICY_ROOT)' || disp='(empty)'
                    fi ;;
        esac
        prov="$hint"
        [ -n "${CONFIG_ENV_SET[$key]+x}" ] && prov="${AMBER}[env override]${R}${DIM} $hint"
        _settings_row "$([ "$i" = "$cur" ] && echo 1 || echo 0)" "$key" "$disp" "$prov"
    done
    printf '\n'
    if [ "$cur" = "$n" ]; then printf '   %s❯%s  %s💾 Save → lekiwi.conf%s\n' "$ACC" "$R" "$B$ACC" "$R"
    else printf '      %s💾 Save → lekiwi.conf%s\n' "$ACC" "$R"; fi
    printf '\n'
    [ -n "$msg" ] && printf '  %s\n\n' "$msg"
    printf '  %s%s%s\n' "$BORD" "$RULE_LIGHT" "$R"
    printf '  %s↑↓%s/%sjk%s move   %s←→%s adjust   %s⏎%s edit · browse · save   %sq%s back\n' \
        "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$R$DIM" "$ACC" "$R"
}

# Settings chooser for POLICY_PATH: Auto (newest) / a discovered checkpoint
# (stored RELATIVE to POLICY_ROOT) / browse / type. Operates on do_settings'
# working copy (S_VAL, dirty — dynamic scope) and respects an unsaved
# POLICY_ROOT edit. Cancel = no change. Always returns 0.
_settings_pick_policy() {
    local _root_saved="$POLICY_ROOT" root sel='' picked=1 nrel p ans
    root="${S_VAL[POLICY_ROOT]:-$POLICY_ROOT}"
    POLICY_ROOT="$root"                  # discover_policies reads the global
    discover_policies
    local rels=() opts=("Auto — always the newest checkpoint under POLICY_ROOT")
    for p in "${DISCOVERED_POLICIES[@]}"; do rels+=("${p#"$root"/}"); done
    [ "${#rels[@]}" -gt 0 ] && opts+=("${rels[@]}")
    opts+=("Browse directories…" "Type a path / HF repo id…")
    nrel=${#rels[@]}
    PICKER_LABEL="settings"
    if choose_one "Default eval checkpoint (POLICY_PATH) — root: ${root/#$HOME/\~}" "${opts[@]}"; then
        if [ "$CHOICE_IDX" = 0 ]; then
            sel=''; picked=0             # empty = auto (resolve_policy picks newest)
        elif [ "$CHOICE_IDX" -le "$nrel" ]; then
            sel="${rels[$((CHOICE_IDX-1))]}"; picked=0
        elif [ "$CHOICE_IDX" = $(( nrel + 1 )) ]; then
            if browse_dir "$root" "Pick a checkpoint dir (needs config.json + model.safetensors)"; then
                sel="$BROWSE_RESULT"
                case "$sel" in "$root"/*) sel="${sel#"$root"/}" ;; esac   # store relative when under root
                picked=0
            fi
        else
            printf '\e[?25h\e[H\e[2J\n  %sPOLICY_PATH%s %s(relative = under POLICY_ROOT · absolute path · HF repo id; ⏎ keeps current)%s\n  ❯ ' "$ACC" "$R" "$DIM" "$R"
            flush_typeahead; read -r ans || ans=''
            ans="${ans/#\~/$HOME}"
            [ -n "$ans" ] && { sel="$ans"; picked=0; }
            printf '\e[?25l'
        fi
    fi
    POLICY_ROOT="$_root_saved"
    if [ "$picked" = 0 ] && [ "$sel" != "${S_VAL[POLICY_PATH]}" ]; then
        S_VAL[POLICY_PATH]="$sel"; dirty=1
    fi
    return 0
}

do_settings() {
    # Non-TTY → print the effective config as plain KEY=value (script-friendly).
    local entry key
    if ! { [ -t 0 ] && [ -t 1 ]; }; then
        printf '# effective lekiwi config — env > %s > built-in defaults\n' "${CONF_FILE/#$HOME/\~}"
        for entry in "${CONFIG_SPEC[@]}"; do
            key="${entry%%|*}"
            if [ -n "${CONFIG_ENV_SET[$key]+x}" ]; then printf '%s=%s\t# env override\n' "$key" "${!key}"
            else printf '%s=%s\n' "$key" "${!key}"; fi
        done
        return 0
    fi

    # Working copy: edits land in S_VAL and only reach the globals + conf on Save.
    declare -A S_VAL=()
    local keys=()
    for entry in "${CONFIG_SPEC[@]}"; do
        key="${entry%%|*}"; S_VAL[$key]="${!key}"; keys+=("$key")
    done
    local n=${#keys[@]} fpos=0 dirty=0 msg='' kind hint cur ans step

    # Same errexit/trap/cursor dance as the eval form (see do_eval).
    local _errexit=''; case $- in *e*) _errexit=1 ;; esac
    set +e
    [ -z "${IN_MENU:-}" ] && trap 'printf "\e[?25h\e[0m"; exit 130' INT
    printf '\e[?25l'
    while true; do
        _settings_draw "$fpos" "$msg" "$dirty"
        if [ "$fpos" -lt "$n" ]; then
            cur="${keys[$fpos]}"
            IFS='|' read -r _ kind hint <<< "${CONFIG_SPEC[$fpos]}"
        else
            cur='__save__'; kind=''
        fi
        read_key; msg=''
        case "$KEY" in
            $'\e[A'|k|K) fpos=$(( (fpos - 1 + n + 1) % (n + 1) )) ;;
            $'\e[B'|j|J) fpos=$(( (fpos + 1) % (n + 1) )) ;;
            $'\e[C'|l|L|$'\e[D'|h|H)
                case "$KEY" in $'\e[D'|h|H) step=-1 ;; *) step=1 ;; esac
                case "$kind" in
                    enum:*) _settings_cycle_enum "$cur" "$kind" "$step"; dirty=1 ;;
                    int)    [ "$cur" = CONNECTION_TIME ] && step=$(( step * 60 ))   # whole minutes
                            S_VAL[$cur]=$(( 10#${S_VAL[$cur]:-0} + step ))
                            [ "${S_VAL[$cur]}" -lt 0 ] && S_VAL[$cur]=0
                            dirty=1 ;;
                esac ;;
            ''|$'\n'|$'\r')
                if [ "$cur" = '__save__' ]; then
                    if config_save S_VAL; then
                        for key in "${keys[@]}"; do printf -v "$key" '%s' "${S_VAL[$key]}"; done
                        dirty=0; msg="${OKC}✓ saved to ${CONF_FILE/#$HOME/\~}${R}"
                    else
                        msg="${ERRC}✗ could not write ${CONF_FILE/#$HOME/\~} — check permissions/disk${R}"
                    fi
                elif [ "${kind%%:*}" = enum ]; then
                    _settings_cycle_enum "$cur" "$kind" 1; dirty=1
                elif [ "$cur" = POLICY_PATH ]; then
                    _settings_pick_policy        # checkpoint chooser (auto/discovered/browse/type)
                elif [ "$kind" = path ]; then
                    if browse_dir "${S_VAL[$cur]}" "Pick a directory for $cur"; then
                        [ "$BROWSE_RESULT" != "${S_VAL[$cur]}" ] && { S_VAL[$cur]="$BROWSE_RESULT"; dirty=1; }
                    fi
                else
                    # Inline text edit, same pattern as the eval form's Custom-policy row.
                    printf '\e[?25h\n  %s%s%s %s[⏎ keeps current]%s ' "$ACC" "$cur" "$R" "$DIM" "$R"
                    flush_typeahead; read -r ans || ans=''
                    if [ -n "$ans" ]; then
                        ans="${ans/#\~/$HOME}"
                        if [ "$kind" = int ] && ! [[ "$ans" =~ ^[0-9]+$ ]]; then
                            msg="${ERRC}✗ $cur must be a whole number${R}"
                        elif [ "$ans" != "${S_VAL[$cur]}" ]; then
                            S_VAL[$cur]="$ans"; dirty=1
                        fi
                    fi
                    printf '\e[?25l'
                fi ;;
            q|Q|$'\e')
                printf '\e[?25h'
                if [ "$dirty" = 1 ]; then printf '  %schanges discarded — lekiwi.conf not written.%s\n' "$DIM" "$R"
                else printf '  %ssettings closed.%s\n' "$DIM" "$R"; fi
                [ -z "${IN_MENU:-}" ] && trap - INT
                [ -n "$_errexit" ] && set -e
                return 0 ;;
        esac
    done
}

do_calibrate() {
    ensure_local_env
    banner "Calibrate the SO101 leader arm on $LEADER_PORT (id=$LEADER_ID)"
    printf '  %sℹ the follower motors are calibrated on the Pi, not here.%s\n\n' "$DIM" "$R"
    lerobot-calibrate --teleop.type=so101_leader --teleop.port="$LEADER_PORT" --teleop.id="$LEADER_ID" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# TRAIN — local-GPU SmolVLA fine-tune via lerobot-train + lekiwi_train.yaml
# ─────────────────────────────────────────────────────────────────────────────
# Everything stays on this machine: wandb off + push_to_hub off (yaml), and the
# run is launched with HF_HUB_OFFLINE=1 whenever it initializes from a LOCAL
# checkpoint (the cached SmolVLM2 backbone loads fine offline). Only choosing
# `lerobot/smolvla_base` as init goes online — once — to download the base.

# Form defaults come from the yaml (single source of truth; CLI overrides win).
_train_yaml_int() {  # <top-level-key> <fallback> → integer
    local v; v="$(_yaml_get "$CFG_TRAIN" "^$1:")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s\n' "$v"; else printf '%s\n' "$2"; fi
}
train_dataset_root() {
    local r; r="$(_yaml_get "$CFG_TRAIN" '^[[:space:]]+root:')"
    printf '%s\n' "${r:-datasets/lekiwi_dataset}"
}

# Init-checkpoint picker: discovered local checkpoints (offline) / hub base /
# typed path. Sets TRAIN_INIT ('' = cancelled, keep current). Always returns 0.
TRAIN_INIT=''
_train_pick_init() {
    TRAIN_INIT=''
    discover_policies
    local rels=() opts=() p ans nrel
    for p in "${DISCOVERED_POLICIES[@]}"; do rels+=("${p#"$POLICY_ROOT"/}"); done
    [ "${#rels[@]}" -gt 0 ] && opts+=("${rels[@]}")
    opts+=("lerobot/smolvla_base — fresh base (one-time HF hub download)" "Type a path / hub id…")
    nrel=${#rels[@]}
    PICKER_LABEL="train"
    choose_one "Initialize training from" "${opts[@]}" || return 0
    if [ "$CHOICE_IDX" -lt "$nrel" ]; then
        TRAIN_INIT="${DISCOVERED_POLICIES[$CHOICE_IDX]}"
    elif [ "$CHOICE_IDX" = "$nrel" ]; then
        TRAIN_INIT="lerobot/smolvla_base"
    else
        printf '\e[?25h\e[H\e[2J\n  %sinit checkpoint dir or hub id%s %s[⏎ keeps current]%s ' "$ACC" "$R" "$DIM" "$R"
        flush_typeahead; read -r ans || ans=''
        ans="${ans/#\~/$HOME}"
        [ -n "$ans" ] && TRAIN_INIT="$ans"
        printf '\e[?25l'
    fi
    return 0
}

# Paint one frame of the train form. Snapshot-testable via LEKIWI_TRAIN_RENDER_TEST.
#   _train_draw <cur> <run> <init> <steps> <batch> <sfreq> <msg>
_train_draw() {
    local cur="$1" run="$2" init="$3" steps="$4" batch="$5" sfreq="$6" msg="$7"
    local init_disp dsroot nep gpu_note
    case "$init" in
        "$POLICY_ROOT"/*) init_disp="${init#"$POLICY_ROOT"/}" ;;
        *)                init_disp="${init/#$HOME/\~}" ;;
    esac
    dsroot="$(train_dataset_root)"; nep="$(dataset_episodes "$dsroot")"
    [ -n "$GPU_NAME" ] && gpu_note="${OKC}●${R} ${DIM}${GPU_NAME} (4 GB — lower Batch on CUDA OOM)${R}" \
                       || gpu_note="${ERRC}none — CPU training is impractically slow${R}"
    printf '\e[H\e[2J\n'
    printf '  %s%s◆ LEKIWI%s  %strain%s\n' "$B" "$ACC" "$R" "$DIM" "$R"
    printf '  %s%s%s\n\n' "$ACC" "$RULE_HEAVY" "$R"
    printf '  %sFine-tune SmolVLA — local GPU only%s\n' "$B" "$R"
    printf '  %sdataset %s%s%s %s(%s episodes) · GPU %s · light recipe: vision frozen, expert-only%s\n' \
        "$DIM" "$R$AMBER" "$dsroot" "$R$DIM" "$R$DIM" "$nep" "$gpu_note" "$R"
    printf '  %swandb off · push_to_hub off · hub offline unless init = smolvla_base%s\n\n' "$DIM" "$R"
    _eval_row "$cur" name  "Run name"   "$run"       "output → ${POLICY_ROOT/#$HOME/\~}/<name>"
    _eval_row "$cur" init  "Init from"  "$init_disp" "local checkpoint = fully offline"
    _eval_row "$cur" steps "Steps"      "$steps"     "←→ ±1000"
    _eval_row "$cur" batch "Batch size" "$batch"     "←→ ±1 — lower first on CUDA OOM"
    _eval_row "$cur" save  "Save every" "$sfreq"     "steps between checkpoints (←→ ±500)"
    printf '\n'
    if [ "$cur" = start ]; then printf '   %s❯%s  %s▶ Start training%s\n' "$ACC" "$R" "$B$ACC" "$R"
    else printf '      %s%s▶ Start training%s\n' "$ACC" "$B" "$R"; fi
    printf '\n'
    [ -n "$msg" ] && printf '  %s\n\n' "$msg"
    printf '  %s%s%s\n' "$BORD" "$RULE_LIGHT" "$R"
    printf '  %s↑↓%s/%sjk%s move   %s←→%s adjust   %s⏎%s edit / pick / start   %sq%s cancel\n' \
        "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$R$DIM" "$ACC" "$R"
}

# Validate + launch lerobot-train. <mode> = fresh|resume.
#   _train_launch <mode> <run> <init> <steps> <batch> <sfreq> [extra CLI args…]
_train_launch() {
    local mode="$1" run="$2" init="$3" steps="$4" batch="$5" sfreq="$6"; shift 6
    local outdir="$POLICY_ROOT/$run" offline=1 hub_note args=() envv=()
    if [ "$mode" = fresh ] && [ -d "$init" ]; then
        if [ ! -f "$init/config.json" ] || [ ! -f "$init/model.safetensors" ]; then
            echo "${ERRC}✗${R} init '$init' is not a valid checkpoint (need config.json + model.safetensors)." >&2
            return 1
        fi
    fi
    # Local-only guarantee: force hub offline unless the init itself is a hub id.
    if [ "$mode" = fresh ] && [ ! -d "$init" ]; then
        offline=0; hub_note="${AMBER}hub ONLINE for this run — downloading '$init' once${R}"
    else
        hub_note="${OKC}hub OFFLINE (HF_HUB_OFFLINE=1) — nothing leaves this machine${R}"
    fi
    [ "$offline" = 1 ] && envv=(HF_HUB_OFFLINE=1 HF_DATASETS_OFFLINE=1)

    ensure_local_env
    banner "Train (lerobot-train) — $run · steps=$steps · batch=$batch${mode:+ · $mode}"
    printf '  %soutput:  %s%s%s\n' "$DIM" "$R$AMBER" "${outdir/#$HOME/\~}" "$R"
    printf '  %snetwork: %s\n' "$DIM" "$hub_note"
    [ -z "$GPU_NAME" ] && printf '  %s⚠ no NVIDIA GPU detected — this will crawl on CPU.%s\n' "$AMBER" "$R"
    printf '  %sℹ Ctrl+C stops; checkpoints land every %s steps — Resume continues from the last one.%s\n\n' \
        "$DIM" "$sfreq" "$R"

    # NOTE: --config_path MUST be the single-token `=` form — lerobot's
    # parser.parse_arg() only matches `--key=value`, and both the yaml
    # policy-block extraction and the resume lookup depend on it (verified:
    # the space form silently skips both).
    if [ "$mode" = resume ]; then
        # The saved train_config of a SERVER-trained run carries remote paths
        # (remote output_dir + dataset root) and a server batch size — override
        # all of them to LOCAL values so resume works on this machine too.
        args=(--resume=true --config_path="$outdir/checkpoints/last/pretrained_model/train_config.json"
              --output_dir="$outdir"
              --dataset.root="$(train_dataset_root)"
              --dataset.repo_id="$(_yaml_get "$CFG_TRAIN" '^[[:space:]]+repo_id:')"
              --batch_size="$batch"
              --num_workers="$(_train_yaml_int num_workers 4)")
        [ -n "$steps" ] && args+=(--steps="$steps")
    else
        args=(--config_path="$CFG_TRAIN" --policy.path="$init"
              --output_dir="$outdir" --job_name="$run"
              --steps="$steps" --batch_size="$batch" --save_freq="$sfreq")
        [ -n "$GPU_NAME" ] && args+=(--policy.device=cuda)
    fi
    env "${envv[@]}" lerobot-train "${args[@]}" "$@"
}

do_train() {
    # Fine-tune SmolVLA on the locally recorded dataset, on THIS machine's GPU.
    # TTY → one-screen form; non-TTY → headless with yaml defaults + date name.
    local run init steps batch sfreq
    steps="$(_train_yaml_int steps 20000)"
    batch="$(_train_yaml_int batch_size 8)"
    sfreq="$(_train_yaml_int save_freq 5000)"
    run="local_$(date +%y%m%d)"
    discover_policies
    if [ "${#DISCOVERED_POLICIES[@]}" -gt 0 ]; then init="${DISCOVERED_POLICIES[0]}"
    else init="lerobot/smolvla_base"; fi
    PICKER_LABEL="train"

    # Explicit --resume on the CLI: pass the args through untouched — the run's
    # saved train_config carries everything, and mixing our fresh-run flags
    # (--policy.path etc.) in would knock lerobot-train out of its resume branch.
    if args_have_resume "$@"; then
        ensure_local_env
        banner "Train — resume (args passed through to lerobot-train)"
        env HF_HUB_OFFLINE=1 HF_DATASETS_OFFLINE=1 lerobot-train "$@"
        return
    fi

    if ! { [ -t 0 ] && [ -t 1 ]; }; then
        if [ -d "$POLICY_ROOT/$run" ]; then
            echo "${ERRC}✗${R} run dir '$POLICY_ROOT/$run' already exists." >&2
            echo "  resume:  ./$SELF train --resume=true --config_path=$POLICY_ROOT/$run/checkpoints/last/pretrained_model/train_config.json" >&2
            return 1
        fi
        _train_launch fresh "$run" "$init" "$steps" "$batch" "$sfreq" "$@"
        return
    fi

    local fpos=0 msg='' cur ans focus=(name init steps batch save start) fcount=6
    local _errexit=''; case $- in *e*) _errexit=1 ;; esac
    set +e
    [ -z "${IN_MENU:-}" ] && trap 'printf "\e[?25h\e[0m"; exit 130' INT
    printf '\e[?25l'
    while true; do
        [ "$fpos" -ge "$fcount" ] && fpos=$((fcount-1)); [ "$fpos" -lt 0 ] && fpos=0
        cur="${focus[$fpos]}"
        _train_draw "$cur" "$run" "$init" "$steps" "$batch" "$sfreq" "$msg"
        read_key; msg=''
        case "$KEY" in
            $'\e[A'|k|K) fpos=$(( (fpos - 1 + fcount) % fcount )) ;;
            $'\e[B'|j|J) fpos=$(( (fpos + 1) % fcount )) ;;
            $'\e[C'|l|L)
                case "$cur" in
                    steps) steps=$(( steps + 1000 )) ;;
                    batch) batch=$(( batch + 1 )) ;;
                    save)  sfreq=$(( sfreq + 500 )) ;;
                esac ;;
            $'\e[D'|h|H)
                case "$cur" in
                    steps) steps=$(( steps - 1000 )); [ "$steps" -lt 1000 ] && steps=1000 ;;
                    batch) batch=$(( batch - 1 ));    [ "$batch" -lt 1 ] && batch=1 ;;
                    save)  sfreq=$(( sfreq - 500 ));  [ "$sfreq" -lt 500 ] && sfreq=500 ;;
                esac ;;
            ''|$'\n'|$'\r')
                case "$cur" in
                    name)
                        printf '\e[?25h\n  %sRun name%s %s[⏎ keeps %s]%s ' "$ACC" "$R" "$DIM" "$run" "$R"
                        flush_typeahead; read -r ans || ans=''
                        if [ -n "$ans" ]; then
                            if [[ "$ans" =~ ^[A-Za-z0-9._-]+$ ]]; then run="$ans"
                            else msg="${ERRC}✗ name must be letters/digits/._- only${R}"; fi
                        fi
                        printf '\e[?25l' ;;
                    init)
                        _train_pick_init
                        [ -n "$TRAIN_INIT" ] && init="$TRAIN_INIT" ;;
                    steps|batch|save)
                        printf '\e[?25h\n  %svalue%s ' "$ACC" "$R"
                        flush_typeahead; read -r ans || ans=''
                        if [ -n "$ans" ]; then
                            if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -gt 0 ]; then
                                case "$cur" in steps) steps=$ans ;; batch) batch=$ans ;; save) sfreq=$ans ;; esac
                            else msg="${ERRC}✗ must be a positive number${R}"; fi
                        fi
                        printf '\e[?25l' ;;
                    start)
                        if [ -f "$POLICY_ROOT/$run/checkpoints/last/pretrained_model/train_config.json" ]; then
                            local prev_steps
                            prev_steps="$(jq -r '.steps // 0' "$POLICY_ROOT/$run/checkpoints/last/pretrained_model/train_config.json" 2>/dev/null || echo 0)"
                            if choose_one "Run \"$run\" already has checkpoints (trained to $prev_steps steps)." \
                                "Resume   — continue this run from its last checkpoint" \
                                "Cancel   — go back (e.g. pick a new name)"; then
                                case "$CHOICE_IDX" in
                                    0)  printf '\e[?25h\e[H\e[2J\n  %sNew TOTAL steps%s %s[⏎ keeps %s — already reached = exits at once]%s ' \
                                            "$ACC" "$R" "$DIM" "$prev_steps" "$R"
                                        flush_typeahead; read -r ans || ans=''
                                        local rsteps=''
                                        [[ "$ans" =~ ^[0-9]+$ ]] && rsteps="$ans"
                                        printf '\e[?25h'
                                        [ -z "${IN_MENU:-}" ] && trap - INT
                                        [ -n "$_errexit" ] && set -e
                                        _train_launch resume "$run" "$init" "$rsteps" "$batch" "$sfreq" "$@"
                                        return ;;
                                    *) : ;;
                                esac
                            fi
                        elif [ -d "$POLICY_ROOT/$run" ] && [ -n "$(ls -A "$POLICY_ROOT/$run" 2>/dev/null || true)" ]; then
                            msg="${ERRC}✗ '$run' exists (no checkpoint) — pick another name${R}"
                        else
                            printf '\e[?25h'
                            [ -z "${IN_MENU:-}" ] && trap - INT
                            [ -n "$_errexit" ] && set -e
                            _train_launch fresh "$run" "$init" "$steps" "$batch" "$sfreq" "$@"
                            return
                        fi ;;
                esac ;;
            q|Q|$'\e')
                printf '\e[?25h'; printf '  %scancelled — nothing trained.%s\n' "$DIM" "$R"
                [ -z "${IN_MENU:-}" ] && trap - INT
                [ -n "$_errexit" ] && set -e
                return 0 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────────────────────────────────────────
# Print the header comment block (line 2 → first non-comment line), stripped of
# the leading "# ". Range-free so it stays correct as the header grows/shrinks.
print_help() { sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^#\s\{0,1\}//'; }

run_action() {
    local act="$1"; shift || true
    case "$act" in
        host-launch|launch|l) do_host_launch ;;
        host-kill|kill|k)     do_host_kill ;;
        teleop|t)             do_teleop "$@" ;;
        record|r)             do_record "$@" ;;
        replay|p)             do_replay "$@" ;;
        view|viz|v)           do_view "$@" ;;
        calibrate|c)          do_calibrate "$@" ;;
        eval|rollout|e)       do_eval "$@" ;;
        settings|config|s)    do_settings "$@" ;;
        train)                do_train "$@" ;;
        -h|--help|help)       print_help ;;
        *) echo "${ERRC}✗${R} unknown action: '$act'" >&2
           echo "  valid: host-launch host-kill teleop record replay view calibrate train eval settings" >&2; return 1 ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Modern ANSI menu
# ─────────────────────────────────────────────────────────────────────────────
#            id        icon  label            hint                                   section   enabled
ITEMS=(
"host-launch|🚀|Launch host|start the ZMQ host on the Pi (asks minutes)|CONTROL|1"
"host-kill|🛑|Kill host|stop the host server on the Pi|CONTROL|1"
"teleop|🎮|Teleop|arm follows leader + keyboard base|DATA|1"
"record|🔴|Record|capture a dataset → datasets/|DATA|1"
"replay|📼|Replay|play back a recorded episode|DATA|1"
"view|🔎|View|browse a recorded episode in Rerun (no host)|DATA|1"
"calibrate|🎯|Calibrate|SO101 leader-arm calibration|DATA|1"
"train|🧠|Train|fine-tune SmolVLA on the local GPU|LEARN|1"
"eval|📊|Eval|rollout a trained policy (watch, no record)|LEARN|1"
"settings|🔧|Settings|view & edit config → lekiwi.conf|SETUP|1"
)
N=${#ITEMS[@]}

render_row() {  # idx sel
    local idx=$1 sel=$2 id icon label hint section en padded ptr lblcol soon=''
    IFS='|' read -r id icon label hint section en <<< "${ITEMS[$idx]}"
    printf -v padded '%-12s' "$label"
    [ "$en" = 0 ] && soon=" ${AMBER}·soon${R}"
    if [ "$idx" = "$sel" ]; then ptr="${ACC}❯${R}"; lblcol="${B}${ACC}"
    else ptr=' '; { [ "$en" = 0 ] && lblcol="${DIM}"; } || lblcol=''; fi
    printf '   %s  %s  %s%s%s%s   %s%s%s\n' "$ptr" "$icon" "$lblcol" "$padded" "$R" "$soon" "$DIM" "$hint" "$R"
}

draw_menu() {
    local sel=$1 i id icon label hint section en prev=''
    printf '\e[H\e[2J\n'
    printf '  %s%s◆ LEKIWI%s  %smobile-manipulator control%s\n' "$B" "$ACC" "$R" "$DIM" "$R"
    printf '  %s%s%s\n' "$ACC" "$RULE_HEAVY" "$R"
    printf '   %shost %s%s%s · env %s%s%s · GPU %s\n' "$DIM" "$R$AMBER" "$LEKIWI_HOST" "$R$DIM" "$R$AMBER" "$LAPTOP_ENV" "$R$DIM" "$GPU_STATUS"
    for i in $(seq 0 $((N-1))); do
        IFS='|' read -r id icon label hint section en <<< "${ITEMS[$i]}"
        if [ "$section" != "$prev" ]; then printf '\n  %s%s%s\n' "$SECT" "$section" "$R"; prev="$section"; fi
        render_row "$i" "$sel"
    done
    printf '\n  %s%s%s\n' "$BORD" "$RULE_LIGHT" "$R"
    printf '  %s↑↓%s/%sjk%s move   %s⏎%s select   %s1-%s%s jump   %sq%s quit\n' "$ACC" "$DIM" "$ACC" "$DIM" "$ACC" "$R$DIM" "$ACC" "$(( N > 9 ? 9 : N ))" "$R$DIM" "$ACC" "$R"
}

run_choice() {  # sel
    local id; IFS='|' read -r id _ <<< "${ITEMS[$1]}"
    printf '\e[?25h\e[H\e[2J\e[3J'   # show cursor + clear (pure ANSI, no terminfo dep)
    run_action "$id" || true
    printf '\n  %sPress Enter to return to the menu…%s' "$DIM" "$R"; flush_typeahead; read -r _ || true
    printf '\e[?25l'
}

menu_loop() {
    { [ -t 0 ] && [ -t 1 ]; } || { echo "The menu needs an interactive terminal. Use: ./$SELF <action>"; exit 1; }
    IN_MENU=1   # tells actions (e.g. do_eval) the menu owns the INT/EXIT traps
    # Children (lerobot, ssh) get a default SIGINT so Ctrl+C stops THEM; this no-op
    # trap keeps the menu alive instead of dying with the child.
    trap ':' INT
    trap 'printf "\e[?25h\e[0m"' EXIT
    printf '\e[?25l'
    local sel=0 key
    while true; do
        draw_menu "$sel"
        read_key; key=$KEY
        case "$key" in
            $'\e[A'|k|K)     sel=$(( (sel - 1 + N) % N )) ;;
            $'\e[B'|j|J)     sel=$(( (sel + 1) % N )) ;;
            ''|$'\n'|$'\r')  run_choice "$sel" ;;
            [1-9])           [ "$key" -le "$N" ] && run_choice "$((key-1))" ;;
            q|Q|$'\e')       break ;;
        esac
    done
    printf '\e[?25h\e[H\e[2J\e[3J'; printf '👋 see you\n'   # clear via pure ANSI
}

# ── Entry point ──
setup_colors
config_load
compute_status
if [ "${LEKIWI_RENDER_TEST:-}" = 1 ]; then draw_menu "${2:-0}"; exit 0; fi
# Snapshot one eval-form frame:  LEKIWI_EVAL_RENDER_TEST=1 ./lekiwi.sh x <cur> <psel> <backend>
# Uses the SAME dynamic discovery as the real form; only falls back to a static
# sample when $POLICY_ROOT has no checkpoints (so the demo still shows scrolling).
if [ "${LEKIWI_EVAL_RENDER_TEST:-}" = 1 ]; then
    discover_policies
    if [ "${#DISCOVERED_POLICIES[@]}" -eq 0 ]; then
        DISCOVERED_POLICIES=(
            "$POLICY_ROOT/run_20k_tc/checkpoints/030000/pretrained_model"
            "$POLICY_ROOT/run_20k_tc/checkpoints/020000/pretrained_model"
            "$POLICY_ROOT/run_20k_tc/checkpoints/010000/pretrained_model"
            "$POLICY_ROOT/run_20k_tc/checkpoints/last/pretrained_model"
            "$POLICY_ROOT/run_20k/checkpoints/last/pretrained_model"
        )
    fi
    # Resolve the default the same way do_eval does (auto/relative/absolute) — but
    # without re-running discover_policies, which would wipe the static seed above.
    _rt_def="$POLICY_PATH"
    if [ -z "$_rt_def" ]; then _rt_def="${DISCOVERED_POLICIES[0]:-}"
    elif [ "${_rt_def#/}" = "$_rt_def" ] && [ -d "$POLICY_ROOT/$_rt_def" ]; then _rt_def="$POLICY_ROOT/$_rt_def"; fi
    EVAL_DEFAULT_ABS="$_rt_def"
    _rt_pidx=-1
    for (( _rt_i=0; _rt_i<${#DISCOVERED_POLICIES[@]}; _rt_i++ )); do
        [ "${DISCOVERED_POLICIES[$_rt_i]}" = "$_rt_def" ] && _rt_pidx=$_rt_i || true
    done
    _eval_draw "${2:-policy}" "${3:-0}" "$_rt_pidx" "$_rt_def" "${4:-rtc}" 20 60 0 ""; exit 0
fi
# Snapshot one train frame:  LEKIWI_TRAIN_RENDER_TEST=1 ./lekiwi.sh x <focused-field>
if [ "${LEKIWI_TRAIN_RENDER_TEST:-}" = 1 ]; then
    discover_policies
    _rt_init="lerobot/smolvla_base"
    [ "${#DISCOVERED_POLICIES[@]}" -gt 0 ] && _rt_init="${DISCOVERED_POLICIES[0]}"
    _train_draw "${2:-name}" "local_$(date +%y%m%d)" "$_rt_init" \
        "$(_train_yaml_int steps 20000)" "$(_train_yaml_int batch_size 8)" "$(_train_yaml_int save_freq 5000)" ""
    exit 0
fi
# Snapshot one settings frame:  LEKIWI_SETTINGS_RENDER_TEST=1 ./lekiwi.sh x <focused-idx> <dirty>
# Seeds S_VAL from the effective config loaded above — deliberately does NOT call
# config_load again (a re-snapshot would falsely tag every field as [env override]).
if [ "${LEKIWI_SETTINGS_RENDER_TEST:-}" = 1 ]; then
    declare -A S_VAL=()
    for _e in "${CONFIG_SPEC[@]}"; do _k="${_e%%|*}"; S_VAL[$_k]="${!_k}"; done
    _settings_draw "${2:-0}" "" "${3:-0}"; exit 0
fi
if [ $# -gt 0 ]; then run_action "$@"; else menu_loop; fi
