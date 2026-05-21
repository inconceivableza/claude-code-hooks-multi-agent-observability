#!/usr/bin/env bash
# planq.sh — Plan queue management for devcontainers.
#
# Subcommands described by --help

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Walk up from SCRIPT_DIR to find the workspace root. A git submodule has a
# .git *file* (not directory), so we skip it and keep walking until we find a
# .git directory — that's the actual project root.
_find_workspace_root() {
    local dir
    dir="$(cd "$1/.." && pwd)"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.git" ]; then
            echo "$dir"
            return
        fi
        if [ -f "$dir/.git" ] && [ -d "$dir/plans" ]; then
            echo "$dir"
            return
        fi
        dir="$(dirname "$dir")"
    done
    # Fallback: one level up from SCRIPT_DIR
    cd "$1/.." && pwd
}
WORKSPACE_ROOT="$(_find_workspace_root "$SCRIPT_DIR")"
PLANS_DIR="$WORKSPACE_ROOT/plans"

# ── Determine planq file ──────────────────────────────────────────────────────

_get_planq_file() {
    echo "$PLANS_DIR/planq-order.txt"
}

PLANQ_FILE="$(_get_planq_file)"
ARCHIVE_DIR="$PLANS_DIR/archive"
HISTORY_FILE="$ARCHIVE_DIR/planq-history.txt"

# ── V1 → V2 format migration ────────────────────────────────────────────────
# V1: "# done: task: foo.md", "# underway: - task: bar.md", "  - task: baz.md"
# V2: "- [done] task: foo.md", "  - [underway] task: bar.md", "    - task: baz.md"
_migrate_v1_to_v2() {
    local file="$1"
    [ -f "$file" ] || return 0
    # Detect V1: any line starting with "# <valid-status>: "
    grep -qE '^# (done|underway|auto-queue|awaiting-commit|awaiting-plan|deferred): ' "$file" || return 0

    # Back up the original
    local dir base
    dir="$(dirname "$file")"
    base="$(basename "$file")"
    cp "$file" "${dir}/${base%.txt}-v1.bak"

    local tmp
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip blank lines and pure comments
        if [ -z "$line" ] || [[ "$line" == "#"* && ! "$line" == "# done: "* && ! "$line" == "# underway: "* && ! "$line" == "# auto-queue: "* && ! "$line" == "# awaiting-commit: "* && ! "$line" == "# awaiting-plan: "* && ! "$line" == "# deferred: "* ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        local status="" content=""
        if   [[ "$line" == "# done: "* ]];           then status="done";           content="${line#"# done: "}"
        elif [[ "$line" == "# underway: "* ]];        then status="underway";       content="${line#"# underway: "}"
        elif [[ "$line" == "# auto-queue: "* ]];      then status="auto-queue";     content="${line#"# auto-queue: "}"
        elif [[ "$line" == "# awaiting-commit: "* ]]; then status="awaiting-commit"; content="${line#"# awaiting-commit: "}"
        elif [[ "$line" == "# awaiting-plan: "* ]];   then status="awaiting-plan";  content="${line#"# awaiting-plan: "}"
        elif [[ "$line" == "# deferred: "* ]];        then status="deferred";       content="${line#"# deferred: "}"
        else content="$line"
        fi
        # content is now e.g. "- task: bar.md" (subtask) or "task: foo.md" (top-level)
        # or "  - task: baz.md" (depth-2 subtask)
        # Convert old depth encoding to V2 indentation:
        #   "task: ..."       → depth 0 → "- ..."
        #   "- task: ..."     → depth 1 → "  - ..."
        #   "  - task: ..."   → depth 2 → "    - ..."
        local spaces="${content%%[![:space:]]*}"
        local after="${content#"$spaces"}"
        local indent="" task_part=""
        if [[ "$after" == "- "* ]]; then
            # Old-style subtask: spaces + "- " + rest
            local old_depth=$(( ${#spaces} / 2 + 1 ))
            indent="$(printf '%*s' $(( old_depth * 2 )) '')"
            task_part="${after#"- "}"
        else
            # Top-level task (no "- " prefix)
            indent=""
            task_part="$after"
        fi
        if [ -n "$status" ]; then
            printf '%s\n' "${indent}- [${status}] ${task_part}" >> "$tmp"
        else
            printf '%s\n' "${indent}- ${task_part}" >> "$tmp"
        fi
    done < "$file"
    mv "$tmp" "$file"
}

# Migrate planq files on startup
_migrate_v1_to_v2 "$PLANQ_FILE"
[ -f "$HISTORY_FILE" ] && _migrate_v1_to_v2 "$HISTORY_FILE"

# ── Parse helpers ─────────────────────────────────────────────────────────────

# Extract the nesting depth from a V2 line. depth = indent / 2.
_content_depth() {
    local content="$1"
    local spaces="${content%%[![:space:]]*}"
    printf '%d' $(( ${#spaces} / 2 ))
}

# Build a dotted number string ("1", "2.1", "3.1.2", …) from the depth_nums array,
# then update depth_nums for the given depth.
# Uses the caller's `depth_nums` array (passed by name via nameref or global).
# Increments depth_nums[depth], zeroes depth_nums[depth+1…].
_dotted_num_advance() {
    local depth="$1"
    depth_nums[$depth]=$(( ${depth_nums[$depth]:-0} + 1 ))
    local d
    for (( d = depth + 1; d < 8; d++ )); do depth_nums[$d]=0; done
    local result="${depth_nums[0]:-0}"
    for (( d = 1; d <= depth; d++ )); do result="${result}.${depth_nums[$d]:-0}"; done
    printf '%s' "$result"
}

# Advance the dotted counter for the given depth (in the global depth_nums array),
# and set the caller's "dotted" variable to the resulting dotted number string.
# Must be called without command substitution to avoid subshell issues.
# Usage: _dotted_num_step <depth>  — result goes into $dotted (caller's scope)
_dotted_num_step() {
    local _d="$1" _r _j
    depth_nums[$_d]=$(( ${depth_nums[$_d]:-0} + 1 ))
    for (( _j = _d + 1; _j < 8; _j++ )); do depth_nums[$_j]=0; done
    _r="${depth_nums[0]:-0}"
    for (( _j = 1; _j <= _d; _j++ )); do _r="${_r}.${depth_nums[$_j]:-0}"; done
    dotted="$_r"
}

# Compute depth of a line and store in $depth (caller's scope).
# V2 format: all task lines are "(  )*- [status] type: value", depth = indent/2.
# No command substitution — sets $depth directly.
_content_depth_step() {
    local _content="$1" _spaces
    _spaces="${_content%%[![:space:]]*}"
    depth=$(( ${#_spaces} / 2 ))
}

# V2 status values that appear in brackets
_V2_STATUSES="done|underway|auto-queue|awaiting-commit|awaiting-plan|deferred"

# Extract status from a V2 line. Sets _v2_status in caller scope ("" if pending).
# Input: the part after "- ", e.g. "[done] task: foo.md" or "task: foo.md"
_v2_extract_status() {
    local _after_dash="$1"
    _v2_status=""
    if [[ "$_after_dash" == "["* ]]; then
        _v2_status="${_after_dash%%]*}"
        _v2_status="${_v2_status#"["}"
    fi
}

# Strip V2 line to just "type: value +flags" (no indent, no "- ", no "[status] ").
# Sets _v2_task_part in caller scope.
_v2_strip_line() {
    local _line="$1"
    local _spaces="${_line%%[![:space:]]*}"
    local _rest="${_line#"$_spaces"}"
    # Strip "- "
    _rest="${_rest#"- "}"
    # Strip "[status] " if present
    if [[ "$_rest" == "["* ]]; then
        _rest="${_rest#*"] "}"
    fi
    _v2_task_part="$_rest"
}

# Get the indent prefix for a V2 line (everything before "- ")
_v2_indent() {
    local _line="$1"
    local _spaces="${_line%%[![:space:]]*}"
    printf '%s' "$_spaces"
}

# ── Filter helpers ────────────────────────────────────────────────────────────

# Resolve a filter token → sets _flt_exclude (0/1), _flt_kind (status/type/unknown), _flt_value.
_filter_resolve() {
    local _tok="$1"
    _flt_exclude=0
    case "$_tok" in
        no-*) _flt_exclude=1; _tok="${_tok#no-}" ;;
        -*)   _flt_exclude=1; _tok="${_tok#-}" ;;
    esac
    case "$_tok" in
        done|d)                  _flt_kind="status"; _flt_value="done" ;;
        underway|u)              _flt_kind="status"; _flt_value="underway" ;;
        inactive|i|pending)      _flt_kind="status"; _flt_value="" ;;
        auto-queue|queue|q)      _flt_kind="status"; _flt_value="auto-queue" ;;
        awaiting-commit|ac)      _flt_kind="status"; _flt_value="awaiting-commit" ;;
        awaiting-plan|ap)        _flt_kind="status"; _flt_value="awaiting-plan" ;;
        deferred|df)             _flt_kind="status"; _flt_value="deferred" ;;
        task|t)                  _flt_kind="type";   _flt_value="task" ;;
        plan|pl)                 _flt_kind="type";   _flt_value="plan" ;;
        make-plan|mp)            _flt_kind="type";   _flt_value="make-plan" ;;
        investigate|inv)         _flt_kind="type";   _flt_value="investigate" ;;
        unnamed-task|ut|unnamed) _flt_kind="type";   _flt_value="unnamed-task" ;;
        manual-test|mt)          _flt_kind="type";   _flt_value="manual-test" ;;
        manual-commit)           _flt_kind="type";   _flt_value="manual-commit" ;;
        manual-task)             _flt_kind="type";   _flt_value="manual-task" ;;
        agent-test|at)           _flt_kind="type";   _flt_value="agent-test" ;;
        auto-test)               _flt_kind="type";   _flt_value="auto-test" ;;
        auto-commit)             _flt_kind="type";   _flt_value="auto-commit" ;;
        *)                       _flt_kind="unknown"; _flt_value="$_tok" ;;
    esac
}

# Check if a task (status=$1, type=$2) passes all filter tokens ($3…).
# Returns 0 (passes) or 1 (filtered out). AND logic: all tokens must pass.
_filter_check_task() {
    local _st="$1" _tp="$2"
    shift 2
    local _tok _flt_exclude _flt_kind _flt_value _matches
    for _tok in "$@"; do
        [ -z "$_tok" ] && continue
        _filter_resolve "$_tok"
        _matches=0
        case "$_flt_kind" in
            status) [ "$_st" = "$_flt_value" ] && _matches=1 ;;
            type)   [ "$_tp" = "$_flt_value" ] && _matches=1 ;;
            *)      _matches=1 ;;
        esac
        [ "$_flt_exclude" -eq 0 ] && [ "$_matches" -eq 0 ] && return 1
        [ "$_flt_exclude" -eq 1 ] && [ "$_matches" -eq 1 ] && return 1
    done
    return 0
}

_list_tasks() {
    # $@ = optional filter tokens (parsed from -f/--filter/-r by cmd_list)
    if [ ! -f "$PLANQ_FILE" ]; then
        echo "(no planq file at $PLANQ_FILE)"
        return
    fi
    local _v2_status _v2_task_part depth dotted

    if [ $# -eq 0 ]; then
        # No filters — simple single-pass display
        depth_nums=()
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            [[ "$line" == "#"* ]] && continue
            _v2_extract_status "${line#*"- "}"
            _content_depth_step "$line"; _dotted_num_step "$depth"
            _v2_strip_line "$line"
            case "$_v2_status" in
                done)             printf "  \033[2m✅ %-5s  %s\033[0m\n" "$dotted" "$_v2_task_part" ;;
                underway)         printf "  \033[33m⏳ %-5s  %s\033[0m\n" "$dotted" "$_v2_task_part" ;;
                auto-queue)       printf "  \033[36m⏱  %-5s  %s\033[0m\n" "$dotted" "$_v2_task_part" ;;
                awaiting-commit)  printf "  \033[35m💾 %-5s  %s\033[0m\n" "$dotted" "$_v2_task_part" ;;
                awaiting-plan)    printf "  \033[36m📋 %-5s  %s\033[0m\n" "$dotted" "$_v2_task_part" ;;
                deferred)         printf "  \033[2m💤 %-5s  %s\033[0m\n" "$dotted" "$_v2_task_part" ;;
                *)                printf "  ▶  %-5s  %s\n" "$dotted" "$_v2_task_part" ;;
            esac
        done < "$PLANQ_FILE"
        return
    fi

    # Filtered display:
    # Phase 1 — collect all tasks (including deferred) into parallel arrays
    local _fl _fs _ft _fd _fdt
    _fl=(); _fs=(); _ft=(); _fd=(); _fdt=()
    depth_nums=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        _v2_extract_status "${line#*"- "}"
        _content_depth_step "$line"
        _v2_strip_line "$line"
        _fl+=("$line")
        _fs+=("$_v2_status")
        _ft+=("${_v2_task_part%%:*}")
        _fd+=("$depth")
    done < "$PLANQ_FILE"
    local _n="${#_fl[@]}"

    # Phase 2 — compute dotted numbers for ALL tasks (consistent with unfiltered view)
    depth_nums=()
    local _i
    for (( _i=0; _i<_n; _i++ )); do
        _dotted_num_step "${_fd[$_i]}"
        _fdt+=("$dotted")
    done

    # Phase 3 — determine which tasks directly match the filter
    local _fm _fa
    _fm=(); _fa=()
    for (( _i=0; _i<_n; _i++ )); do
        if _filter_check_task "${_fs[$_i]}" "${_ft[$_i]}" "$@"; then
            _fm+=( 1 ); else _fm+=( 0 ); fi
        _fa+=( 0 )
    done

    # Phase 4 — propagate: mark ancestors of matching tasks
    local _j _need
    for (( _i=0; _i<_n; _i++ )); do
        [ "${_fm[$_i]}" -eq 0 ] && continue
        [ "${_fd[$_i]}" -eq 0 ] && continue
        _need=$(( _fd[_i] - 1 ))
        for (( _j=_i-1; _j>=0 && _need>=0; _j-- )); do
            if [ "${_fd[$_j]}" -eq "$_need" ]; then
                _fa[$_j]=1
                _need=$(( _need - 1 ))
            fi
        done
    done

    # Phase 5 — display visible tasks (direct match shown normally; ancestor shown dimmed)
    for (( _i=0; _i<_n; _i++ )); do
        [ "${_fm[$_i]}" -eq 0 ] && [ "${_fa[$_i]}" -eq 0 ] && continue
        _v2_strip_line "${_fl[$_i]}"
        local _st="${_fs[$_i]}" _dt="${_fdt[$_i]}"
        if [ "${_fm[$_i]}" -eq 1 ]; then
            case "$_st" in
                done)            printf "  \033[2m✅ %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                underway)        printf "  \033[33m⏳ %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                auto-queue)      printf "  \033[36m⏱  %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                awaiting-commit) printf "  \033[35m💾 %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                awaiting-plan)   printf "  \033[36m📋 %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                deferred)        printf "  \033[2m💤 %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                *)               printf "  ▶  %-5s  %s\n" "$_dt" "$_v2_task_part" ;;
            esac
        else
            # Ancestor of a matching subtask — show dimmed
            case "$_st" in
                done)            printf "  \033[2m✅ %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                underway)        printf "  \033[2m⏳ %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                auto-queue)      printf "  \033[2m⏱  %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                awaiting-commit) printf "  \033[2m💾 %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                awaiting-plan)   printf "  \033[2m📋 %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                deferred)        printf "  \033[2m💤 %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
                *)               printf "  \033[2m▶  %-5s  %s\033[0m\n" "$_dt" "$_v2_task_part" ;;
            esac
        fi
    done
}

# Outputs: line_number TAB task_line  for a task identified by dotted number ("5.1", "3.2.1").
_find_task_by_dotted_number() {
    local target="$1"
    [ ! -f "$PLANQ_FILE" ] && return
    depth_nums=()
    local n=0
    while IFS= read -r line; do
        n=$((n + 1))
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        local after_dash="${line#*"- "}" _v2_status
        _v2_extract_status "$after_dash"
        local depth dotted
        _content_depth_step "$line"; _dotted_num_step "$depth"
        if [ "$dotted" = "$target" ]; then
            printf '%d\t%s\n' "$n" "$line"
            return
        fi
    done < "$PLANQ_FILE"
}

# Given a file line number, compute the dotted task number for that line.
# Outputs the dotted number (e.g. "5" or "3.2") on stdout; empty if not found.
_get_dotted_number_for_line() {
    local target_line="$1"
    [ ! -f "$PLANQ_FILE" ] && return
    depth_nums=()
    local n=0
    while IFS= read -r line; do
        n=$((n + 1))
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        local after_dash="${line#*"- "}" _v2_status
        _v2_extract_status "$after_dash"
        local depth dotted
        _content_depth_step "$line"; _dotted_num_step "$depth"
        if [ "$n" -eq "$target_line" ]; then
            printf '%s' "$dotted"
            return
        fi
    done < "$PLANQ_FILE"
}

# Outputs: line_number TAB line  (first pending task only — no [status] bracket)
_find_next_task() {
    [ ! -f "$PLANQ_FILE" ] && return
    local n=0
    while IFS= read -r line; do
        n=$((n + 1))
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        # V2: pending = no [status] bracket after "- "
        local after_dash="${line#*"- "}" _v2_status
        _v2_extract_status "$after_dash"
        [ -z "$_v2_status" ] || continue
        printf '%d\t%s\n' "$n" "$line"
        return
    done < "$PLANQ_FILE"
}

# Outputs: line_number TAB line  for the task at visible position N (1-based)
# V2: returns the full line (with indent, "- ", "[status]")
_find_task_by_number() {
    local target="$1"
    [ ! -f "$PLANQ_FILE" ] && return
    local n=0 i=0
    while IFS= read -r line; do
        n=$((n + 1))
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        local after_dash="${line#*"- "}" _v2_status
        _v2_extract_status "$after_dash"
        i=$((i + 1))
        if [ "$i" -eq "$target" ]; then
            printf '%d\t%s\n' "$n" "$line"
            return
        fi
    done < "$PLANQ_FILE"
}

# Outputs: line_number TAB task_line  for a task identified by number, filename, or text
_find_task_by_identifier() {
    local ident="$1"
    if [[ "$ident" =~ ^[0-9]+$ ]] || [[ "$ident" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
        _find_task_by_dotted_number "$ident"
        return
    fi
    [ ! -f "$PLANQ_FILE" ] && return
    local n=0
    while IFS= read -r line; do
        n=$((n + 1))
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        # V2: extract task_part (type: value +flags) for comparison
        local _v2_task_part
        _v2_strip_line "$line"
        local task_value="${_v2_task_part#*: }"
        # Strip commit/plan flags from comparison
        local cmp_value="${task_value% +auto-commit}"
        cmp_value="${cmp_value% +stage-commit}"
        cmp_value="${cmp_value% +manual-commit}"
        cmp_value="${cmp_value% +add-after}"
        cmp_value="${cmp_value% +add-end}"
        cmp_value="${cmp_value% +auto-queue-plan}"
        if [ "$cmp_value" = "$ident" ] || [ "$task_value" = "$ident" ]; then
            printf '%d\t%s\n' "$n" "$line"
            return
        fi
    done < "$PLANQ_FILE"
}

# V2 _mark helpers: reconstruct line as "{indent}- [status] {task_part}"
# original_line is the full V2 line (with indent and "- " and optional "[status] ")
_mark_with_status() {
    local line_num="$1" original_line="$2" new_status="$3"
    local indent task_part
    indent="$(_v2_indent "$original_line")"
    _v2_strip_line "$original_line"; task_part="$_v2_task_part"
    local new_line
    if [ -n "$new_status" ]; then
        new_line="${indent}- [${new_status}] ${task_part}"
    else
        new_line="${indent}- ${task_part}"
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v n="$line_num" -v newline="$new_line" \
        'NR == n { print newline; next } { print }' \
        "$PLANQ_FILE" > "$tmp"
    mv "$tmp" "$PLANQ_FILE"
}

_mark_done()             { _mark_with_status "$1" "$2" "done"; }
_mark_underway()         { _mark_with_status "$1" "$2" "underway"; }
_mark_inactive()         { _mark_with_status "$1" "$2" ""; }
_mark_auto_queue()       { _mark_with_status "$1" "$2" "auto-queue"; }
_mark_awaiting_commit()  { _mark_with_status "$1" "$2" "awaiting-commit"; }
_mark_awaiting_plan()    { _mark_with_status "$1" "$2" "awaiting-plan"; }
_mark_deferred()         { _mark_with_status "$1" "$2" "deferred"; }

# Set or clear the commit flag (+auto-commit / +stage-commit / +manual-commit) on a task line.
# flag: "auto-commit" | "stage-commit" | "manual-commit" | "none" (clears)
_set_commit_flag() {
    local line_num="$1" flag="$2"
    # Read the raw line, preserve any status prefix, strip old commit flags, append new one
    local raw_line
    raw_line=$(sed -n "${line_num}p" "$PLANQ_FILE")
    # Strip existing commit flags from the raw line
    local new_line
    new_line="${raw_line/ +auto-commit/}"
    new_line="${new_line/ +stage-commit/}"
    new_line="${new_line/ +manual-commit/}"
    if [ "$flag" != "none" ]; then
        new_line="${new_line} +${flag}"
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v n="$line_num" -v newline="$new_line" \
        'NR == n { print newline; next } { print }' \
        "$PLANQ_FILE" > "$tmp"
    mv "$tmp" "$PLANQ_FILE"
}


_insert_after_line() {
    local line_num="$1" new_line="$2"
    local tmp
    tmp="$(mktemp)"
    awk -v n="$line_num" -v new="$new_line" \
        'NR == n { print; print new; next } { print }' \
        "$PLANQ_FILE" > "$tmp"
    mv "$tmp" "$PLANQ_FILE"
}

# Outputs: line_number TAB line  (first task with given status)
_find_next_with_status() {
    local want_status="$1"
    [ ! -f "$PLANQ_FILE" ] && return
    local n=0
    while IFS= read -r line; do
        n=$((n + 1))
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        local after_dash="${line#*"- "}" _v2_status
        _v2_extract_status "$after_dash"
        [ "$_v2_status" = "$want_status" ] || continue
        printf '%d\t%s\n' "$n" "$line"
        return
    done < "$PLANQ_FILE"
}
_find_next_auto_task()           { _find_next_with_status "auto-queue"; }
_find_next_awaiting_commit_task() { _find_next_with_status "awaiting-commit"; }
_find_next_awaiting_plan_task()  { _find_next_with_status "awaiting-plan"; }

# Wait until the target plan file appears in the queue (for awaiting-plan tasks).
_wait_for_plan() {
    local line_num="$1" task_line="$2"
    local task_type task_value task_auto_commit task_stage_commit task_manual_commit task_add_after task_add_end task_auto_queue_plan
    _parse_task "$task_line"
    local target_plan="${task_value/#make-plan-/plan-}"
    echo "awaiting-plan: waiting for 'plan: ${target_plan}' to appear in the queue..."
    while true; do
        if [ ! -f "$PLANQ_FILE" ]; then sleep 5; continue; fi
        # Check if the task is still awaiting-plan
        local current_line
        current_line="$(sed -n "${line_num}p" "$PLANQ_FILE" 2>/dev/null || true)"
        current_line="${current_line#"${current_line%%[![:space:]]*}"}"
        if [[ "$current_line" != *"[awaiting-plan]"* ]]; then
            echo "awaiting-plan: task no longer in awaiting-plan state."
            return
        fi
        # Check if the plan has been added to the queue
        if grep -qF "plan: ${target_plan}" "$PLANQ_FILE" 2>/dev/null; then
            echo "awaiting-plan: plan found in queue, marking task done."
            _mark_done "$line_num" "$task_line"
            _notify_daemon
            return
        fi
        sleep 5
    done
}

_AUTO_TEST_PENDING="$PLANS_DIR/auto-test-pending.json"
_AUTO_TEST_RESPONSE="$PLANS_DIR/auto-test-response.txt"
_AUTO_COMMIT_CONFIG="$PLANS_DIR/auto-commit-config.txt"
_PLANQ_SETTINGS="$PLANS_DIR/planq-settings.txt"

# Read a setting from global then per-project settings files.
# Per-project ($PLANS_DIR/planq-settings.txt) overrides global
# (~/.local/devcontainer-sandbox/planq-settings).
_read_planq_setting() {
    local key="$1"
    local global_settings="${HOME}/.local/devcontainer-sandbox/planq-settings"
    local value=""
    if [ -f "$global_settings" ]; then
        value="$(grep "^${key}=" "$global_settings" 2>/dev/null | head -1 | cut -d= -f2-)"
    fi
    if [ -f "$_PLANQ_SETTINGS" ]; then
        local project_value
        project_value="$(grep "^${key}=" "$_PLANQ_SETTINGS" 2>/dev/null | head -1 | cut -d= -f2-)"
        [ -n "$project_value" ] && value="$project_value"
    fi
    printf '%s' "$value"
}

# Write an auto-test-pending record so the dashboard can prompt the user
_write_auto_test_pending() {
    local command="$1" output="$2" exit_code="$3"
    # Escape for JSON
    local escaped_output
    escaped_output="$(printf '%s' "$output" | head -c 4096 | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '""')"
    printf '{"command":%s,"output":%s,"exit_code":%d}\n' \
        "$(printf '%s' "$command" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '""')" \
        "$escaped_output" \
        "$exit_code" \
        > "$_AUTO_TEST_PENDING"
}

_clear_auto_test_pending() {
    rm -f "$_AUTO_TEST_PENDING" "$_AUTO_TEST_RESPONSE"
}

# Wait for a response via dashboard or terminal. Returns 0=continue, 1=abort.
_wait_auto_test_response() {
    rm -f "$_AUTO_TEST_RESPONSE"
    # If we're in a terminal, allow local input too
    if [ -t 0 ]; then
        echo ""
        echo "Tests failed. Waiting for response (or press Enter to continue, Ctrl+C to abort):"
        echo "  (dashboard users can also respond via the Plan Queue panel)"
        local resp=""
        read -r -t 60 resp || true
        _clear_auto_test_pending
        case "${resp,,}" in
            abort|a|no|n) return 1 ;;
            *) return 0 ;;
        esac
    fi
    # Non-interactive: poll for response file (written by dashboard via daemon relay)
    echo "Tests failed. Waiting for dashboard response..."
    local waited=0
    while [ "$waited" -lt 3600 ]; do
        sleep 2
        waited=$((waited + 2))
        if [ -f "$_AUTO_TEST_RESPONSE" ]; then
            local resp
            resp="$(cat "$_AUTO_TEST_RESPONSE" 2>/dev/null || true)"
            _clear_auto_test_pending
            case "${resp,,}" in
                abort|a|no|n) return 1 ;;
                *) return 0 ;;
            esac
        fi
    done
    _clear_auto_test_pending
    return 1  # Timed out — abort
}

_delete_line() {
    local line_num="$1"
    local tmp
    tmp="$(mktemp)"
    awk -v n="$line_num" 'NR != n { print }' "$PLANQ_FILE" > "$tmp"
    mv "$tmp" "$PLANQ_FILE"
}

_parse_task() {
    # Args: task_line (full V2 line) → sets task_type, task_value, task_auto_commit, etc.
    local line="$1"
    # V2: strip indent + "- " + optional "[status] " to get "type: value +flags"
    local _v2_task_part
    _v2_strip_line "$line"
    line="$_v2_task_part"
    task_type="${line%%:*}"
    task_value="${line#*: }"
    task_auto_commit=""
    task_stage_commit=""
    task_manual_commit=""
    task_add_after=""
    task_add_end=""
    task_add_subtask=""
    task_auto_queue_plan=""
    if [[ "$task_value" == *" +auto-commit" ]]; then
        task_auto_commit="1"
        task_value="${task_value% +auto-commit}"
    fi
    if [[ "$task_value" == *" +stage-commit" ]]; then
        task_stage_commit="1"
        task_value="${task_value% +stage-commit}"
    fi
    if [[ "$task_value" == *" +manual-commit" ]]; then
        task_manual_commit="1"
        task_value="${task_value% +manual-commit}"
    fi
    if [[ "$task_value" == *" +auto-queue-plan" ]]; then
        task_auto_queue_plan="1"
        task_value="${task_value% +auto-queue-plan}"
    fi
    if [[ "$task_value" == *" +add-after" ]]; then
        task_add_after="1"
        task_value="${task_value% +add-after}"
    fi
    if [[ "$task_value" == *" +add-end" ]]; then
        task_add_end="1"
        task_value="${task_value% +add-end}"
    fi
    if [[ "$task_value" == *" +add-subtask" ]]; then
        task_add_subtask="1"
        task_value="${task_value% +add-subtask}"
    fi
}

# List entries in the archive history file
_list_archive() {
    if [ ! -f "$HISTORY_FILE" ]; then
        echo "(no archive at $HISTORY_FILE)"
        return
    fi
    local i=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        i=$((i + 1))
        local after_dash="${line#*"- "}" _v2_status _v2_task_part
        _v2_extract_status "$after_dash"
        _v2_strip_line "$line"
        case "$_v2_status" in
            done)     printf "  \033[2m✅ %-3d  %s\033[0m\n" "$i" "$_v2_task_part" ;;
            underway) printf "  \033[33m⏳ %-3d  %s\033[0m\n" "$i" "$_v2_task_part" ;;
            *)        printf "  ▶  %-3d  %s\n" "$i" "$_v2_task_part" ;;
        esac
    done < "$HISTORY_FILE"
}

# Outputs: line_number TAB line  for the Nth entry in the archive (1-based)
_find_archive_by_number() {
    local target="$1"
    [ ! -f "$HISTORY_FILE" ] && return
    local n=0 i=0
    while IFS= read -r line; do
        n=$((n + 1))
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        i=$((i + 1))
        if [ "$i" -eq "$target" ]; then
            printf '%d\t%s\n' "$n" "$line"
            return
        fi
    done < "$HISTORY_FILE"
}

# Outputs: line_number TAB line  for an archive entry by number or text
_find_archive_by_identifier() {
    local ident="$1"
    if [[ "$ident" =~ ^[0-9]+$ ]]; then
        _find_archive_by_number "$ident"
        return
    fi
    [ ! -f "$HISTORY_FILE" ] && return
    local n=0
    while IFS= read -r line; do
        n=$((n + 1))
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        local _v2_task_part
        _v2_strip_line "$line"
        local task_value="${_v2_task_part#*: }"
        if [ "$task_value" = "$ident" ] || [ "$_v2_task_part" = "$ident" ]; then
            printf '%d\t%s\n' "$n" "$line"
            return
        fi
    done < "$HISTORY_FILE"
}

# Archive one task: read original line (with status prefix) from planq, store in history,
# move file if applicable, then remove from planq
# Outputs line_num TAB task_content for each subtask line of the task at parent_line_num.
# Subtasks are all lines after the parent whose depth > parent depth, until a shallower line.
_get_subtasks() {
    local parent_line_num="$1"
    [ ! -f "$PLANQ_FILE" ] && return
    local parent_raw depth
    parent_raw="$(awk -v n="$parent_line_num" 'NR == n { print; exit }' "$PLANQ_FILE")"
    _content_depth_step "$parent_raw"
    local parent_depth=$depth
    local n=0
    while IFS= read -r line; do
        n=$((n + 1))
        [ "$n" -le "$parent_line_num" ] && continue
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue
        _content_depth_step "$line"
        [ "$depth" -le "$parent_depth" ] && break
        printf '%d\t%s\n' "$n" "$line"
    done < "$PLANQ_FILE"
}

_archive_one_task() {
    local line_num="$1" task_line="$2" mode="${3:-both}"
    # mode: "both" (default) | "history" (write history only) | "delete" (delete from planq only)
    local task_type task_value task_auto_commit
    _parse_task "$task_line"

    if [ "$mode" != "delete" ]; then
        mkdir -p "$ARCHIVE_DIR"

        if [ "$task_type" = "task" ] || [ "$task_type" = "plan" ] || [ "$task_type" = "make-plan" ] || [ "$task_type" = "investigate" ]; then
            if [ -f "$PLANS_DIR/$task_value" ]; then
                mv "$PLANS_DIR/$task_value" "$ARCHIVE_DIR/$task_value"
                echo "  Moved: plans/$task_value → plans/archive/$task_value"
            fi
            if [ "$task_type" = "investigate" ]; then
                local feedback="${task_value/#investigate-/feedback-}"
                if [ -f "$PLANS_DIR/$feedback" ]; then
                    mv "$PLANS_DIR/$feedback" "$ARCHIVE_DIR/$feedback"
                    echo "  Moved: plans/$feedback → plans/archive/$feedback"
                fi
            fi
        fi

        # Read original V2 line (preserving indent and [status]) before deleting
        local original_line
        original_line="$(awk -v n="$line_num" 'NR == n { print; exit }' "$PLANQ_FILE")"
        printf '%s\n' "$original_line" >> "$HISTORY_FILE"
    fi

    if [ "$mode" != "history" ]; then
        _delete_line "$line_num"
    fi
}

# ── Subcommands ───────────────────────────────────────────────────────────────

cmd_list() {
    local archive="" _next_filter=0
    local _filters
    _filters=()
    for arg in "$@"; do
        if [ "$_next_filter" -eq 1 ]; then
            _filters+=("$arg"); _next_filter=0; continue
        fi
        case "$arg" in
            --archive|-a)   archive=1 ;;
            --remaining|-r) _filters+=("-done") ;;
            --filter|-f)    _next_filter=1 ;;
            -f:*)           _filters+=("${arg#-f:}") ;;
            --filter:*)     _filters+=("${arg#--filter:}") ;;
            --help|-h)      usage_list; return 0 ;;
            -*)             echo "Unknown option: $arg" >&2; usage_list; return 1 ;;
        esac
    done

    if [ -n "$archive" ]; then
        echo "Archive: $HISTORY_FILE"
        _list_archive
    else
        echo "Planq: $PLANQ_FILE"
        if [ "${#_filters[@]}" -gt 0 ]; then
            _list_tasks "${_filters[@]}"
        else
            _list_tasks
        fi
    fi
}

_show_task_details() {
    local label="$1" task_line="$2" plans_base="$3"
    local task_type task_value task_auto_commit task_stage_commit task_manual_commit task_add_after task_add_end task_auto_queue_plan
    _parse_task "$task_line"

    echo "${label}:"
    printf "  Type:  %s\n" "$task_type"
    if [ "$task_type" = "task" ] || [ "$task_type" = "plan" ]; then
        printf "  File:  plans/%s\n" "$task_value"
        if [ -f "$plans_base/$task_value" ]; then
            echo "  --- preview ---"
            head -5 "$plans_base/$task_value" | sed 's/^/  /'
        fi
    elif [ "$task_type" = "make-plan" ]; then
        local target_plan="${task_value/#make-plan-/plan-}"
        printf "  Prompt file: plans/%s\n" "$task_value"
        printf "  Plan target: plans/%s\n" "$target_plan"
        if [ -f "$plans_base/$task_value" ]; then
            echo "  --- prompt preview ---"
            head -5 "$plans_base/$task_value" | sed 's/^/  /'
        else
            echo "  (prompt file not found)"
        fi
    elif [ "$task_type" = "investigate" ]; then
        local feedback="${task_value/#investigate-/feedback-}"
        printf "  Prompt file:   plans/%s\n" "$task_value"
        printf "  Feedback file: plans/%s\n" "$feedback"
        if [ -f "$plans_base/$task_value" ]; then
            echo "  --- prompt preview ---"
            head -5 "$plans_base/$task_value" | sed 's/^/  /'
        else
            echo "  (prompt file not found)"
        fi
        if [ -f "$plans_base/$feedback" ]; then
            echo "  --- result ---"
            cat "$plans_base/$feedback" | sed 's/^/  /'
        fi
    elif [[ "$task_type" == manual-test || "$task_type" == manual-commit || "$task_type" == manual-task ]] && [[ "$task_value" == *.md ]]; then
        printf "  File:  plans/%s\n" "$task_value"
        if [ -f "$plans_base/$task_value" ]; then
            echo "  --- preview ---"
            head -5 "$plans_base/$task_value" | sed 's/^/  /'
        fi
    else
        printf "  Desc:  %s\n" "$task_value"
    fi
    [ -n "$task_auto_commit" ] && printf "  Auto-commit after: yes\n"
    [ -n "$task_stage_commit" ] && printf "  Stage-commit after: yes\n"
    [ -n "$task_manual_commit" ] && printf "  Manual-commit after: yes\n"
    if [ "$task_type" = "make-plan" ]; then
        if [ -n "$task_add_subtask" ]; then
            printf "  Plan disposition: add-subtask%s\n" "${task_auto_queue_plan:+ (auto-queue)}"
        elif [ -n "$task_add_after" ]; then
            printf "  Plan disposition: add-after%s\n" "${task_auto_queue_plan:+ (auto-queue)}"
        elif [ -n "$task_add_end" ]; then
            printf "  Plan disposition: add-end%s\n" "${task_auto_queue_plan:+ (auto-queue)}"
        else
            printf "  Plan disposition: manual-review\n"
        fi
    fi
}

cmd_show() {
    local archive="" task_num=""
    for arg in "$@"; do
        case "$arg" in
            --archive|-a) archive=1 ;;
            --help|-h)    echo "Usage: planq show [-a|--archive] [N]"; echo "  Show details of task N (default: next pending), or archive entry N with -a."; return 0 ;;
            -*)           echo "Unknown option: $arg" >&2; echo "Usage: planq show [-a|--archive] [N]" >&2; return 1 ;;
            [0-9]*)       task_num="$arg" ;;
        esac
    done

    if [ -n "$archive" ]; then
        local next
        if [ -n "$task_num" ]; then
            next="$(_find_archive_by_number "$task_num")"
            if [ -z "$next" ]; then
                echo "No archive entry #$task_num in $HISTORY_FILE" >&2; return 1
            fi
            local label="Archive #$task_num"
        else
            next="$(_find_archive_by_number 1)"
            if [ -z "$next" ]; then
                echo "No entries in archive $HISTORY_FILE"
                return 0
            fi
            local label="Archive #1"
        fi
        local task_line
        task_line="$(printf '%s' "$next" | cut -f2-)"
        _show_task_details "$label" "$task_line" "$ARCHIVE_DIR"
        return 0
    fi

    local next label
    if [ -n "$task_num" ]; then
        next="$(_find_task_by_identifier "$task_num")"
        if [ -z "$next" ]; then
            echo "No task #$task_num in $PLANQ_FILE" >&2; return 1
        fi
        label="Task #$task_num"
    else
        next="$(_find_next_task)"
        if [ -z "$next" ]; then
            echo "No pending tasks in $PLANQ_FILE"
            return 0
        fi
        label="Next task"
    fi

    local task_line
    task_line="$(printf '%s' "$next" | cut -f2-)"
    _show_task_details "$label" "$task_line" "$PLANS_DIR"
}

cmd_run() {
    local dry_run="" task_num=""
    for arg in "$@"; do
        case "$arg" in
            --dry-run|-n) dry_run=1 ;;
            --*|-?) ;;  # skip other flags
            *)     task_num="$arg" ;;
        esac
    done

    local next
    if [ -n "$task_num" ]; then
        next="$(_find_task_by_identifier "$task_num")"
        if [ -z "$next" ]; then
            echo "No task #$task_num in $PLANQ_FILE" >&2; return 1
        fi
    else
        next="$(_find_next_task)"
        if [ -z "$next" ]; then
            echo "No pending tasks in $PLANQ_FILE"
            return 0
        fi
    fi

    local line_num task_line task_type task_value task_auto_commit task_stage_commit task_manual_commit task_add_after task_add_end task_auto_queue_plan
    line_num="$(printf '%s' "$next" | cut -f1)"
    task_line="$(printf '%s' "$next" | cut -f2-)"
    _parse_task "$task_line"

    echo "Running task: $task_line"

    if [ -n "$dry_run" ]; then
        case "$task_type" in
            task)          echo "[dry-run] Would run: claude \"\$(cat $PLANS_DIR/$task_value)\"" ;;
            plan)          echo "[dry-run] Would run: claude \"Read plans/$task_value and implement the plan\"" ;;
            make-plan)     echo "[dry-run] Would run: claude \"\$(cat $PLANS_DIR/$task_value) Write the plan to plans/${task_value/#make-plan-/plan-}.\"" ;;
            investigate)   echo "[dry-run] Would run: claude \"\$(cat $PLANS_DIR/$task_value) Write your findings to plans/${task_value/#investigate-/feedback-}.\"" ;;
            unnamed-task)  echo "[dry-run] Would run: claude \"$task_value\"" ;;
            auto-test)     echo "[dry-run] Would run test command: $task_value" ;;
            agent-test)    echo "[dry-run] Would run: claude \"$task_value\" (as testing agent)" ;;
            auto-commit)   echo "[dry-run] Would run: claude auto-commit $task_value" ;;
            manual-*) echo "[dry-run] Would prompt for manual step: $task_value" ;;
            *)        echo "[dry-run] Unknown task type: $task_type" ;;
        esac
        return 0
    fi

    case "$task_type" in
        task)
            local task_file="$PLANS_DIR/$task_value"
            if [ ! -f "$task_file" ]; then
                echo "Error: task file not found: $task_file" >&2; return 1
            fi
            claude "$(cat "$task_file") REQUIRED FINAL STEP: Write a brief summary of what you accomplished to plans/feedback-${task_value} (create this file even if brief). This summary appears in the project dashboard."
            _mark_done "$line_num" "$task_line"
            ;;

        plan)
            local task_file="$PLANS_DIR/$task_value"
            if [ ! -f "$task_file" ]; then
                echo "Error: plan file not found: $task_file" >&2; return 1
            fi
            claude "Read plans/$task_value and implement the plan described in it. REQUIRED FINAL STEP: Write a brief summary of what you implemented to plans/feedback-${task_value} (create this file even if brief). This summary appears in the project dashboard."
            _mark_done "$line_num" "$task_line"
            ;;

        make-plan)
            local prompt_file="$PLANS_DIR/$task_value"
            if [ ! -f "$prompt_file" ]; then
                echo "Error: prompt file not found: $prompt_file" >&2; return 1
            fi
            local prompt target_plan
            prompt="$(cat "$prompt_file")"
            target_plan="${task_value/#make-plan-/plan-}"
            claude "${prompt} Write the plan to plans/${target_plan}. REQUIRED FINAL STEP: Write a brief summary of the plan you created to plans/feedback-${task_value} (create this file even if brief). This summary appears in the project dashboard."
            if [ -n "$task_add_after" ] || [ -n "$task_add_end" ] || [ -n "$task_add_subtask" ]; then
                _mark_done "$line_num" "$task_line"
                # After marking done the line number is now a done line; insert/append the plan
                local new_plan_task="- plan: ${target_plan}"
                [ -n "$task_auto_queue_plan" ] && new_plan_task="- [auto-queue] plan: ${target_plan}"
                if [ -n "$task_add_subtask" ]; then
                    # Add as subtask (indented under the make-plan task)
                    local _raw_line
                    _raw_line="$(sed -n "${line_num}p" "$PLANQ_FILE" 2>/dev/null || echo "")"
                    local _depth=0
                    local _indent="${_raw_line%%[! ]*}"
                    _depth=$(( ${#_indent} / 2 ))
                    local _child_indent
                    _child_indent="$(printf '%*s' $(( (_depth + 1) * 2 )) '')"
                    new_plan_task="${_child_indent}${new_plan_task}"
                    _insert_after_line "$line_num" "$new_plan_task"
                    echo "make-plan: Added 'plan: ${target_plan}' as subtask."
                elif [ -n "$task_add_after" ]; then
                    _insert_after_line "$line_num" "$new_plan_task"
                    echo "make-plan: Added 'plan: ${target_plan}' after current position."
                else
                    printf '\n%s\n' "$new_plan_task" >> "$PLANQ_FILE"
                    echo "make-plan: Added 'plan: ${target_plan}' at end of queue."
                fi
            else
                # Manual review — mark awaiting-plan and return (skip commit handling)
                _mark_awaiting_plan "$line_num" "$task_line"
                echo "make-plan: Plan written to plans/${target_plan}. Add it to the queue to continue."
                _notify_daemon
                return 0
            fi
            ;;

        investigate)
            local inv_file="$PLANS_DIR/$task_value"
            if [ ! -f "$inv_file" ]; then
                echo "Error: investigate file not found: $inv_file" >&2; return 1
            fi
            local inv_prompt inv_feedback
            inv_prompt="$(cat "$inv_file")"
            inv_feedback="${task_value/#investigate-/feedback-}"
            claude "${inv_prompt} Write your findings and conclusions to plans/${inv_feedback}."
            _mark_done "$line_num" "$task_line"
            ;;

        unnamed-task)
            claude "$task_value"
            _mark_done "$line_num" "$task_line"
            ;;

        auto-test)
            _run_auto_test "$task_value" || { _mark_inactive "$line_num" "$task_line"; _notify_daemon; return 1; }
            _mark_done "$line_num" "$task_line"
            ;;

        agent-test)
            claude "$task_value"
            _mark_done "$line_num" "$task_line"
            ;;

        auto-commit)
            _run_auto_commit "$task_value" || { _mark_inactive "$line_num" "$task_line"; _notify_daemon; return 1; }
            _mark_done "$line_num" "$task_line"
            ;;

        manual-test|manual-commit|manual-task)
            echo ""
            echo "━━━ Manual step required ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            printf "  Type: %s\n" "$task_type"
            if [[ "$task_value" == *.md ]] && [ -f "$PLANS_DIR/$task_value" ]; then
                printf "  File: plans/%s\n" "$task_value"
                echo "  ---"
                cat "$PLANS_DIR/$task_value" | sed 's/^/  /'
            else
                printf "  Task: %s\n" "$task_value"
            fi
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            _mark_underway "$line_num" "$task_line"
            _notify_daemon
            read -r -p "Press Enter when done (or Ctrl+C to abort): "
            _mark_done "$line_num" "$task_line"
            echo "Marked as done."
            ;;

        *)
            echo "Error: Unknown task type '$task_type' in: $task_line" >&2
            return 1
            ;;
    esac

    # If the task had +auto-commit, ask Claude to commit after completion
    if [ -n "$task_auto_commit" ] && [ "$task_type" != "auto-commit" ]; then
        _run_auto_commit "" || { _notify_daemon; return 1; }
    fi

    # If the task had +stage-commit, stage changes and mark awaiting-commit instead of done
    if [ -n "$task_stage_commit" ] && [ "$task_type" != "auto-commit" ]; then
        if _run_stage_commit ""; then
            _mark_awaiting_commit "$line_num" "$task_line"
            echo "stage-commit: changes staged. Commit when ready, then task will be marked done."
        else
            _notify_daemon; return 1
        fi
        _notify_daemon
        return 0
    fi

    # If the task had +manual-commit, mark awaiting-commit (user stages and commits manually)
    if [ -n "$task_manual_commit" ] && [ "$task_type" != "auto-commit" ]; then
        _mark_awaiting_commit "$line_num" "$task_line"
        echo "manual-commit: task complete. Stage and commit changes manually, then task will be marked done."
        _notify_daemon
        return 0
    fi

    _notify_daemon
}

# Run an auto-test: execute the command and handle failure.
# $1 = task_value (command or filename)
# Returns 0 on success/continue, 1 on abort.
_run_auto_test() {
    local task_value="$1"
    local cmd="$task_value"
    # If task_value is a file in plans/, read the command from it
    if [ -f "$PLANS_DIR/$task_value" ]; then
        cmd="$(cat "$PLANS_DIR/$task_value")"
    fi
    echo "Running tests: $cmd"
    local output exit_code
    output="$(eval "$cmd" 2>&1)" || exit_code=$?
    exit_code="${exit_code:-0}"
    echo "$output"
    if [ "$exit_code" -eq 0 ]; then
        echo "Tests passed."
        return 0
    fi
    echo ""
    echo "Tests FAILED (exit code $exit_code)."
    _write_auto_test_pending "$cmd" "$output" "$exit_code"
    _notify_daemon
    if _wait_auto_test_response; then
        return 0
    fi
    echo "Auto-queue aborted by user."
    return 1
}

# Invoke claude, using --continue if _PLANQ_CONTINUE is set.
# Keeps all auto tasks in one continuous session.
_invoke_claude() {
    if [ -n "${_PLANQ_CONTINUE:-}" ]; then
        claude --continue "$@"
    else
        claude "$@"
    fi
}

# Print the relative path of each git submodule that has staged or unstaged changes.
_get_dirty_submodule_paths() {
    local sub_path sub_full staged unst
    while IFS= read -r sub_path; do
        [ -z "$sub_path" ] && continue
        sub_full="${WORKSPACE_ROOT}/${sub_path}"
        staged="$(git -C "$sub_full" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
        unst="$(git -C "$sub_full" diff --name-only 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$staged" -gt 0 ] || [ "$unst" -gt 0 ]; then
            printf '%s\n' "$sub_path"
        fi
    done < <(git -C "$WORKSPACE_ROOT" submodule --quiet foreach 'echo $sm_path' 2>/dev/null || true)
}

# Run an auto-commit task by delegating to Claude.
# $1 = task_value (optional extra instructions for Claude)
# Returns 0 on success, 1 on error/abort.
_run_auto_commit() {
    local task_value="$1"

    # Check for git
    if ! git -C "$WORKSPACE_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
        echo "auto-commit: not a git repository." >&2
        return 1
    fi

    local staged_count unstaged_count
    staged_count="$(git -C "$WORKSPACE_ROOT" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
    unstaged_count="$(git -C "$WORKSPACE_ROOT" diff --name-only 2>/dev/null | wc -l | tr -d ' ')"
    local dirty_subs
    dirty_subs="$(_get_dirty_submodule_paths)"

    if [ "$staged_count" -eq 0 ] && [ "$unstaged_count" -eq 0 ] && [ -z "$dirty_subs" ]; then
        echo "auto-commit: nothing to commit (working tree clean)."
        return 0
    fi

    # Build prompt for Claude, including any config defaults and task instructions
    local claude_prompt="Please commit the current changes to git."

    local extra_instructions=""
    if [ -f "$_AUTO_COMMIT_CONFIG" ]; then
        local conf_title conf_desc
        conf_title="$(grep '^title=' "$_AUTO_COMMIT_CONFIG" 2>/dev/null | head -1 | cut -d= -f2-)"
        conf_desc="$(grep '^description=' "$_AUTO_COMMIT_CONFIG" 2>/dev/null | head -1 | cut -d= -f2-)"
        [ -n "$conf_title" ] && extra_instructions="${extra_instructions}Use this as the commit title: ${conf_title}. "
        [ -n "$conf_desc" ] && extra_instructions="${extra_instructions}Description source: ${conf_desc}. "
    fi
    [ -n "$task_value" ] && extra_instructions="${extra_instructions}${task_value}"

    if [ -n "$dirty_subs" ]; then
        local sub_list
        sub_list="$(printf '%s' "$dirty_subs" | tr '\n' ' ' | sed 's/ $//')"
        extra_instructions="${extra_instructions} The following git submodules also have changes and must be committed as part of this task: ${sub_list}. Commit each submodule first (in its own directory), then stage the updated submodule pointer(s) and commit the parent repository."
    fi

    [ -n "$extra_instructions" ] && claude_prompt="${claude_prompt} ${extra_instructions}"

    echo "auto-commit: asking Claude to commit changes..."
    _invoke_claude "$claude_prompt"
}

# Stage changes and write a commit message via Claude, without committing.
# $1 = task_value (optional extra instructions for Claude)
# Returns 0 on success, 1 on error/abort.
_run_stage_commit() {
    local task_value="$1"

    # Check for git
    if ! git -C "$WORKSPACE_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
        echo "stage-commit: not a git repository." >&2
        return 1
    fi

    local staged_count unstaged_count
    staged_count="$(git -C "$WORKSPACE_ROOT" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
    unstaged_count="$(git -C "$WORKSPACE_ROOT" diff --name-only 2>/dev/null | wc -l | tr -d ' ')"
    local dirty_subs
    dirty_subs="$(_get_dirty_submodule_paths)"

    if [ "$staged_count" -eq 0 ] && [ "$unstaged_count" -eq 0 ] && [ -z "$dirty_subs" ]; then
        echo "stage-commit: nothing to stage (working tree clean)."
        return 0
    fi

    # Build prompt for Claude
    local claude_prompt="Please stage all relevant git changes and write an appropriate commit message to .git/COMMIT_EDITMSG, but do NOT actually commit. Stage the files, then write the commit message to .git/COMMIT_EDITMSG."

    local extra_instructions=""
    if [ -f "$_AUTO_COMMIT_CONFIG" ]; then
        local conf_title conf_desc
        conf_title="$(grep '^title=' "$_AUTO_COMMIT_CONFIG" 2>/dev/null | head -1 | cut -d= -f2-)"
        conf_desc="$(grep '^description=' "$_AUTO_COMMIT_CONFIG" 2>/dev/null | head -1 | cut -d= -f2-)"
        [ -n "$conf_title" ] && extra_instructions="${extra_instructions}Use this as the commit title: ${conf_title}. "
        [ -n "$conf_desc" ] && extra_instructions="${extra_instructions}Description source: ${conf_desc}. "
    fi
    [ -n "$task_value" ] && extra_instructions="${extra_instructions}${task_value}"

    if [ -n "$dirty_subs" ]; then
        local sub_list
        sub_list="$(printf '%s' "$dirty_subs" | tr '\n' ' ' | sed 's/ $//')"
        extra_instructions="${extra_instructions} The following git submodules also have changes: ${sub_list}. For each submodule, stage all relevant changes and write a commit message to <submodule>/.git/COMMIT_EDITMSG (do NOT commit). Then stage the updated submodule pointer(s) in the parent repository."
    fi

    [ -n "$extra_instructions" ] && claude_prompt="${claude_prompt} ${extra_instructions}"

    echo "stage-commit: asking Claude to stage changes and prepare commit message..."
    _invoke_claude "$claude_prompt"
}

# Wait for the user to commit (for awaiting-commit tasks in auto mode).
# $1 = line_num, $2 = task_line
# For +stage-commit: waits until no staged changes remain in the parent or any dirty submodule.
# For +manual-commit: waits until the HEAD commit hash changes in the parent.
# Returns silently if the task status changes away from awaiting-commit.
_wait_for_stage_commit() {
    local line_num="$1" task_line="$2"

    # Determine wait strategy from commit flag in the task line
    local wait_mode="stage"
    if [[ "$task_line" == *"+manual-commit"* ]]; then
        wait_mode="manual"
    fi

    # Snapshot which submodules are dirty at wait-start so we can check them throughout
    local dirty_subs_snapshot
    dirty_subs_snapshot="$(_get_dirty_submodule_paths)"

    if [ "$wait_mode" = "manual" ]; then
        echo "awaiting-commit: waiting for a new commit (manual-commit mode)..."
        if [ -n "$dirty_subs_snapshot" ]; then
            local sub_list
            sub_list="$(printf '%s' "$dirty_subs_snapshot" | tr '\n' ' ' | sed 's/ $//')"
            echo "  Submodules with changes: ${sub_list}"
            echo "  Commit each submodule first, then stage the pointer(s) and commit the parent."
        else
            echo "  Stage and commit your changes, then the task will be marked done."
        fi
    else
        echo "awaiting-commit: waiting for staged changes to be committed..."
        local git_dir
        git_dir="$(git -C "$WORKSPACE_ROOT" rev-parse --git-dir 2>/dev/null || true)"
        [ -n "$git_dir" ] && echo "  Commit message ready: ${git_dir}/COMMIT_EDITMSG"
        if [ -n "$dirty_subs_snapshot" ]; then
            local sub_list
            sub_list="$(printf '%s' "$dirty_subs_snapshot" | tr '\n' ' ' | sed 's/ $//')"
            echo "  Submodule(s) with staged changes: ${sub_list}"
            echo "  Commit each submodule first (git commit in its directory), then commit the parent."
        else
            echo "  Run: git commit"
        fi
    fi
    echo "  To abort: planq mark underway <task>"

    # Snapshot HEAD for manual-commit mode
    local initial_head=""
    if [ "$wait_mode" = "manual" ]; then
        initial_head="$(git -C "$WORKSPACE_ROOT" rev-parse HEAD 2>/dev/null || true)"
    fi

    while true; do
        sleep 3

        # Check if the task is still in awaiting-commit state
        local current_line
        current_line="$(awk -v n="$line_num" 'NR == n { print; exit }' "$PLANQ_FILE" 2>/dev/null || true)"
        current_line="${current_line#"${current_line%%[![:space:]]*}"}"
        if [[ "$current_line" != *"[awaiting-commit]"* ]]; then
            echo "awaiting-commit: task no longer in awaiting-commit state."
            return
        fi

        if [ "$wait_mode" = "manual" ]; then
            # Detect a new commit by parent HEAD hash change
            local current_head
            current_head="$(git -C "$WORKSPACE_ROOT" rev-parse HEAD 2>/dev/null || true)"
            if [ -n "$current_head" ] && [ "$current_head" != "$initial_head" ]; then
                echo "awaiting-commit: new commit detected, marking task as done."
                _mark_done "$line_num" "$task_line"
                _notify_daemon
                return
            fi
        else
            # Detect commit by absence of staged changes in parent and all dirty submodules
            local staged_count all_committed
            staged_count="$(git -C "$WORKSPACE_ROOT" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
            all_committed=1
            if [ "$staged_count" -gt 0 ]; then
                all_committed=0
            else
                local sub_path
                while IFS= read -r sub_path; do
                    [ -z "$sub_path" ] && continue
                    local sub_staged
                    sub_staged="$(git -C "${WORKSPACE_ROOT}/${sub_path}" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
                    if [ "$sub_staged" -gt 0 ]; then
                        all_committed=0
                        break
                    fi
                done <<< "$dirty_subs_snapshot"
            fi
            if [ "$all_committed" -eq 1 ]; then
                echo "awaiting-commit: commit detected, marking task as done."
                _mark_done "$line_num" "$task_line"
                _notify_daemon
                return
            fi
        fi
    done
}

_task_slug() {
    # Generate a slug from the first 5 words of a description string.
    # Output: lowercase, non-alphanumeric chars removed, words joined by hyphens.
    printf '%s' "$1" | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]//g' | tr -s ' ' ' ' | sed 's/^ //;s/ $//' | cut -d' ' -f1-5 | tr ' ' '-'
}

_random_hex7() {
    # Generate a 7-character random hex string (like a short git hash).
    printf '%07x' $(( (RANDOM << 15 | RANDOM) & 0xFFFFFFF ))
}

cmd_create() {
    local task_type="unnamed-task" task_type_explicit="" filename="" slug="" description="" auto_commit="" stage_commit="" manual_commit="" add_after="" add_end="" auto_queue_plan="" parent="" link_type="follow-up" queue_after=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --type|-t) task_type="${2:-}"; task_type_explicit="1"; shift 2 ;;
            --file|-f) filename="${2:-}"; shift 2 ;;
            --slug|-s) slug="${2:-}"; shift 2 ;;
            --parent|-p) parent="${2:-}"; shift 2 ;;
            --link-type|-l) link_type="${2:-}"; shift 2 ;;
            --auto-commit) auto_commit="1"; shift ;;
            --stage-commit) stage_commit="1"; shift ;;
            --manual-commit) manual_commit="1"; shift ;;
            --add-after) add_after="1"; shift ;;
            --add-end) add_end="1"; shift ;;
            --auto-queue-plan) auto_queue_plan="1"; shift ;;
            --queue|-q) queue_after="1"; shift ;;
            --help|-h) usage_create; return 0 ;;
            -*) echo "Unknown option: $1" >&2; usage_create; return 1 ;;
            *) if [ -z "$description" ]; then description="$1"; else description="$description $1"; fi; shift ;;
        esac
    done

    # -s slug: generate filename as $type-$slug.md (type defaults to task)
    if [ -n "$slug" ] && [ -z "$filename" ]; then
        local _slug_type="$task_type"
        [ "$_slug_type" = "unnamed-task" ] && _slug_type="task"
        filename="${_slug_type}-${slug}.md"
        # If type wasn't explicitly given, set it based on the generated prefix
        [ -z "$task_type_explicit" ] && task_type="$_slug_type" && task_type_explicit="1"
    fi

    # planq-order.txt is line-based: newlines in descriptions break parsing.
    # For file-based types (task/plan/make-plan) newlines are fine — they go
    # into the file.  For description-only types, auto-create a task file so
    # the full content is preserved.
    if [ -n "$description" ] && [ -z "$filename" ]; then
        case "$description" in
            *$'\n'*)
                case "$task_type" in
                    unnamed-task|manual-test|manual-commit|manual-task|agent-test)
                        local first_line="${description%%$'\n'*}"
                        local slug
                        slug="$(printf '%s' "$first_line" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | head -c 60)"
                        [ -z "$slug" ] && slug="multiline"
                        filename="task-${slug}.md"
                        local counter=1
                        while [ -f "$PLANS_DIR/$filename" ]; do
                            filename="task-${slug}-${counter}.md"
                            counter=$(( counter + 1 ))
                        done
                        mkdir -p "$PLANS_DIR"
                        printf '%s\n' "$description" > "$PLANS_DIR/$filename"
                        echo "Multiline description saved to: plans/$filename"
                        if [ "$task_type" = "unnamed-task" ]; then
                            task_type="task"
                        fi
                        description=""
                        ;;
                esac
                ;;
        esac
    fi

    # Apply default commit mode from settings if no explicit flag was given
    if [ -z "$auto_commit" ] && [ -z "$stage_commit" ] && [ -z "$manual_commit" ]; then
        local _default_commit_mode
        _default_commit_mode="$(_read_planq_setting DEFAULT_COMMIT_MODE)"
        case "$_default_commit_mode" in
            auto-commit)   auto_commit="1" ;;
            stage-commit)  stage_commit="1" ;;
            manual-commit) manual_commit="1" ;;
        esac
    fi

    # If -f was given but -t was not explicitly set, infer type from filename prefix.
    if [ -n "$filename" ] && [ -z "$task_type_explicit" ]; then
        case "$filename" in
            make-plan-*) task_type="make-plan" ;;
            plan-*)      task_type="plan" ;;
            investigate-*) task_type="investigate" ;;
            *)           task_type="task" ;;
        esac
    fi

    # If unnamed-task with multi-line description, auto-generate a file-based task.
    if [ "$task_type" = "unnamed-task" ] && [ -n "$description" ] && printf '%s' "$description" | grep -q $'\n'; then
        local _slug _rand _auto_fn
        _slug="$(_task_slug "$description")"
        _rand="$(_random_hex7)"
        _auto_fn="task-${_slug}-${_rand}.md"
        mkdir -p "$PLANS_DIR"
        printf '%s\n' "$description" > "$PLANS_DIR/$_auto_fn"
        echo "Auto-generated file for multi-line task: plans/$_auto_fn"
        filename="$_auto_fn"
        task_type="task"
        description=""
    fi

    # Normalize filename: auto-prefix with type if bare, auto-append .md
    if [ -n "$filename" ]; then
        case "$filename" in
            *.md) ;;  # already has extension
            *) filename="${filename}.md" ;;
        esac
        case "$task_type" in
            task|plan|make-plan|investigate|manual-test|manual-commit|manual-task)
                case "$filename" in
                    ${task_type}-*) ;;  # already prefixed
                    *) filename="${task_type}-${filename}" ;;
                esac
                ;;
        esac
    fi

    local task_line
    case "$task_type" in
        task|plan)
            if [ -z "$filename" ]; then
                echo "Error: --file required for task type '$task_type'" >&2; return 1
            fi
            task_line="${task_type}: ${filename}"
            if [ -n "$description" ]; then
                mkdir -p "$PLANS_DIR"
                printf '%s\n' "$description" > "$PLANS_DIR/${filename}"
                echo "Wrote description to: plans/${filename}"
            fi
            ;;
        make-plan)
            if [ -z "$filename" ]; then
                echo "Error: --file required for make-plan (the prompt filename, e.g. make-plan-001.md)" >&2; return 1
            fi
            if [ -z "$description" ]; then
                echo "Error: description (the prompt) required for make-plan" >&2; return 1
            fi
            task_line="${task_type}: ${filename}"
            mkdir -p "$PLANS_DIR"
            printf '%s\n' "$description" > "$PLANS_DIR/${filename}"
            echo "Wrote prompt to: plans/${filename}"
            ;;
        investigate)
            if [ -z "$filename" ]; then
                echo "Error: --file required for investigate (the prompt filename, e.g. investigate-foo.md)" >&2; return 1
            fi
            if [ -z "$description" ]; then
                echo "Error: description (the prompt / question to investigate) required for investigate" >&2; return 1
            fi
            task_line="${task_type}: ${filename}"
            mkdir -p "$PLANS_DIR"
            printf '%s\n' "$description" > "$PLANS_DIR/${filename}"
            echo "Wrote prompt to: plans/${filename}"
            ;;
        unnamed-task|manual-test|manual-commit|manual-task|agent-test|auto-test|auto-commit)
            if [ -n "$filename" ] && case "$task_type" in manual-test|manual-commit|manual-task) true;; *) false;; esac; then
                task_line="${task_type}: ${filename}"
                if [ -n "$description" ]; then
                    mkdir -p "$PLANS_DIR"
                    printf '%s\n' "$description" > "$PLANS_DIR/${filename}"
                    echo "Wrote description to: plans/${filename}"
                fi
            else
                if [ -z "$description" ]; then
                    echo "Error: description required for task type '$task_type'" >&2; return 1
                fi
                task_line="${task_type}: ${description}"
            fi
            ;;
        *)
            echo "Error: unknown task type '$task_type'" >&2; return 1 ;;
    esac

    [ -n "$auto_commit" ] && task_line="${task_line} +auto-commit"
    [ -n "$stage_commit" ] && task_line="${task_line} +stage-commit"
    [ -n "$manual_commit" ] && task_line="${task_line} +manual-commit"
    [ -n "$add_after" ] && task_line="${task_line} +add-after"
    [ -n "$add_end" ] && task_line="${task_line} +add-end"
    [ -n "$auto_queue_plan" ] && task_line="${task_line} +auto-queue-plan"

    mkdir -p "$PLANS_DIR"

    if [ -n "$parent" ]; then
        # Subtask: insert with depth prefix after parent's last descendant
        local parent_info parent_line_num parent_task_line
        parent_info="$(_find_task_by_identifier "$parent")" || true
        if [ -z "$parent_info" ]; then
            echo "Error: parent task '$parent' not found" >&2; return 1
        fi
        parent_line_num="${parent_info%%	*}"
        parent_task_line="${parent_info#*	}"

        # V2: depth is just indent/2 from the raw line
        local parent_raw_line parent_depth=0 depth
        parent_raw_line=$(sed -n "${parent_line_num}p" "$PLANQ_FILE")
        _content_depth_step "$parent_raw_line"
        parent_depth=$depth

        # Build V2 child line: (child_depth * 2 spaces) + "- " + task_line
        local child_depth=$(( parent_depth + 1 ))
        local child_indent
        child_indent="$(printf '%*s' $(( child_depth * 2 )) '')"
        local indented_task_line="${child_indent}- ${task_line}"

        # Find insertion point: after last line in parent's subtree (depth > parent_depth).
        local insert_after="$parent_line_num"
        local n=0
        while IFS= read -r line; do
            n=$(( n + 1 ))
            [ "$n" -le "$parent_line_num" ] && continue
            [ -z "$line" ] && continue
            [[ "$line" == "#"* ]] && continue
            _content_depth_step "$line"
            [ "$depth" -le "$parent_depth" ] && break
            insert_after="$n"
        done < "$PLANQ_FILE"

        local tmp
        tmp="$(mktemp)"
        awk -v n="$insert_after" -v newline="$indented_task_line" \
            'NR == n { print; print newline; next } { print }' \
            "$PLANQ_FILE" > "$tmp"
        mv "$tmp" "$PLANQ_FILE"

        local _created_num
        _created_num="$(_get_dotted_number_for_line $((insert_after + 1)))"
        echo "Created subtask #${_created_num} (depth ${child_depth} under ${parent_task_line%% +*}): $task_line"
    else
        # V2: top-level task = "- type: value +flags"
        printf '%s\n' "- ${task_line}" >> "$PLANQ_FILE"
        local _created_line_count _created_num
        _created_line_count="$(wc -l < "$PLANQ_FILE")"
        _created_num="$(_get_dotted_number_for_line "$_created_line_count")"
        echo "Created #${_created_num}: $task_line"
    fi
    if [ -n "$queue_after" ]; then
        local created_info
        created_info="$(_find_task_by_identifier "${filename:-$description}")"
        if [ -n "$created_info" ]; then
            local created_line_num created_task_line
            created_line_num="${created_info%%	*}"
            created_task_line="${created_info#*	}"
            _mark_auto_queue "$created_line_num" "$created_task_line"
            echo "Marked auto-queue."
        fi
    fi
    _notify_daemon
}

cmd_do() {
    # do = create + immediately run the created task
    # Capture cmd_create output to extract the actual identifier (handles auto-generated
    # filenames for multi-line tasks and type inference for -f without -t).
    local create_out
    create_out="$(cmd_create "$@" 2>&1)" || { printf '%s\n' "$create_out" >&2; return 1; }
    printf '%s\n' "$create_out"

    # Extract the identifier from the "Created #N: TYPE: VALUE" output line
    local created_line ident
    created_line="$(printf '%s\n' "$create_out" | grep '^Created #[0-9]' | head -1)"
    if [ -n "$created_line" ]; then
        local after_hash="${created_line#Created #}"    # "N: TYPE: VALUE [+flags]"
        local after_num="${after_hash#*: }"             # "TYPE: VALUE [+flags]"
        ident="${after_num#*: }"                         # "VALUE [+flags]"
        ident="${ident%% +*}"                            # strip trailing flags
    fi
    if [ -z "$ident" ]; then
        echo "Error: could not determine task identifier to run" >&2; return 1
    fi
    # Mark the task underway before running so the daemon sees it as in-progress
    local task_info line_num task_line
    task_info="$(_find_task_by_identifier "$ident")" || true
    if [ -n "$task_info" ]; then
        line_num="${task_info%%	*}"
        task_line="${task_info#*	}"
        _mark_underway "$line_num" "$task_line"
        _notify_daemon
    fi
    cmd_run "$ident"
}

_notify_daemon() {
    local sandbox_dir="${HOME}/.local/devcontainer-sandbox"
    local pid_file="$sandbox_dir/planq/planq-daemon.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid="$(cat "$pid_file")"
        kill -USR1 "$pid" 2>/dev/null || true
    fi
}

# Auto-set review state to 'developing' when work starts (if not already set or not in developing)
_auto_set_review_developing() {
    local state_file="$WORKSPACE_ROOT/.claude/review-state"
    local current_state=""
    if [ -f "$state_file" ]; then
        current_state="$(grep "^state:" "$state_file" | head -1 | sed 's/^state:[[:space:]]*//')"
    fi
    if [ -z "$current_state" ] || [ "$current_state" != "developing" ]; then
        local timestamp
        timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        mkdir -p "$(dirname "$state_file")"
        {
            echo "state: developing"
            echo "updated: $timestamp"
        } > "$state_file"
    fi
}

# Auto-set review state to 'ready-for-review' when all tasks are done
_auto_set_review_ready() {
    [ ! -f "$PLANQ_FILE" ] && return
    # Check if any pending or auto-queue tasks remain
    local has_pending=0
    while IFS= read -r line; do
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [ -z "$trimmed" ] && continue
        [[ "$trimmed" == "#"* ]] && continue
        has_pending=1
        break
    done < "$PLANQ_FILE"
    if [ "$has_pending" -eq 0 ]; then
        local state_file="$WORKSPACE_ROOT/.claude/review-state"
        local timestamp
        timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        local notes_line=""
        if [ -f "$state_file" ]; then
            notes_line="$(grep "^notes:" "$state_file" || true)"
        fi
        mkdir -p "$(dirname "$state_file")"
        {
            echo "state: ready-for-review"
            echo "updated: $timestamp"
            [ -n "$notes_line" ] && echo "$notes_line"
        } > "$state_file"
        echo "All tasks done — review state set to: ready-for-review"
    fi
}

cmd_mark() {
    local state="${1:-}"
    shift || true
    # Support "state:ident" as a single arg (e.g. m d:7 or m:done 7)
    local _embedded_ident=""
    if [[ "$state" == *:* ]]; then
        _embedded_ident="${state#*:}"
        state="${state%%:*}"
    fi
    if [ -z "$state" ]; then
        echo "Usage: planq mark <done|d|underway|u|inactive|i|queue|q|awaiting-commit|ac|deferred|df> <N|filename|text> [...]" >&2; return 1
    fi
    case "$state" in
        done|d)                  state=done ;;
        underway|u)              state=underway ;;
        inactive|i)              state=inactive ;;
        queue|q|auto-queue|aq)   state=queue ;;
        awaiting-commit|ac)      state=awaiting-commit ;;
        awaiting-plan|ap)        state=awaiting-plan ;;
        deferred|df)             state=deferred ;;
        auto-commit|+ac)         state=auto-commit ;;
        stage-commit|+sc|sc)     state=stage-commit ;;
        manual-commit|+mc|mc)    state=manual-commit ;;
        no-commit|+nc|nc)        state=no-commit ;;
        *) echo "Error: unknown state '$state'. Run 'planq mark --help' for valid states." >&2; return 1 ;;
    esac
    # Parse remaining args: extract --result/--notes flags, collect identifiers
    local mark_result="" mark_notes=""
    local _idents=()
    [ -n "$_embedded_ident" ] && _idents+=("$_embedded_ident")
    local _nf=0
    while [ $# -gt 0 ]; do
        if [ "$_nf" -eq 1 ]; then mark_result="$1"; _nf=0; shift; continue; fi
        if [ "$_nf" -eq 2 ]; then mark_notes="$1";  _nf=0; shift; continue; fi
        case "$1" in
            --result) _nf=1; shift ;;
            --notes)  _nf=2; shift ;;
            *)        _idents+=("$1"); shift ;;
        esac
    done
    if [ ${#_idents[@]} -eq 0 ]; then
        echo "Usage: planq mark <state> <N|filename|text> [...]" >&2; return 1
    fi

    for _ident in "${_idents[@]}"; do
        local next
        next="$(_find_task_by_identifier "$_ident")"
        if [ -z "$next" ]; then
            echo "No matching task for '$_ident' in $PLANQ_FILE" >&2
            continue
        fi
        local line_num task_line
        line_num="$(printf '%s' "$next" | cut -f1)"
        task_line="$(printf '%s' "$next" | cut -f2-)"
        echo "Task: $task_line"
        # Parse task flags (needed for make-plan add-after/add-end logic below)
        local task_type task_value task_auto_commit task_stage_commit task_manual_commit task_add_after task_add_end task_auto_queue_plan
        _parse_task "$task_line"

        case "$state" in
            done)
                # Read the raw file line to detect if already done (avoid duplicate plan insertion)
                local raw_line
                raw_line="$(sed -n "${line_num}p" "$PLANQ_FILE" 2>/dev/null || echo "")"
                _mark_done "$line_num" "$task_line"
                echo "Marked as done."
                if [ -n "$mark_result" ]; then
                    _write_test_result "$task_line" "$mark_result" "$mark_notes"
                fi
                # For make-plan with +add-after, +add-end, or +add-subtask, insert the plan task
                if [ "$task_type" = "make-plan" ] && { [ -n "$task_add_after" ] || [ -n "$task_add_end" ] || [ -n "$task_add_subtask" ]; } && [[ "$raw_line" != *"[done]"* ]]; then
                    local target_plan="${task_value/#make-plan-/plan-}"
                    if grep -qF "plan: ${target_plan}" "$PLANQ_FILE" 2>/dev/null; then
                        echo "make-plan: Plan 'plan: ${target_plan}' already in queue, skipping."
                    else
                        local new_plan_task
                        if [ -n "$task_add_subtask" ]; then
                            # Add as a subtask (indented under the make-plan task)
                            local _parent_depth=0
                            local _parsed
                            _parsed="$(_v2_parse_line "$raw_line" 2>/dev/null)" || true
                            if [ -n "$_parsed" ]; then
                                _parent_depth=$(( ${#_parsed%%	*} / 2 ))
                            fi
                            local _child_indent
                            _child_indent="$(printf '%*s' $(( (_parent_depth + 1) * 2 )) '')"
                            new_plan_task="${_child_indent}- plan: ${target_plan}"
                            [ -n "$task_auto_queue_plan" ] && new_plan_task="${_child_indent}- [auto-queue] plan: ${target_plan}"
                            _insert_after_line "$line_num" "$new_plan_task"
                            echo "make-plan: Added 'plan: ${target_plan}' as subtask."
                        elif [ -n "$task_add_after" ]; then
                            new_plan_task="- plan: ${target_plan}"
                            [ -n "$task_auto_queue_plan" ] && new_plan_task="- [auto-queue] plan: ${target_plan}"
                            _insert_after_line "$line_num" "$new_plan_task"
                            echo "make-plan: Added 'plan: ${target_plan}' after current position."
                        else
                            new_plan_task="- plan: ${target_plan}"
                            [ -n "$task_auto_queue_plan" ] && new_plan_task="- [auto-queue] plan: ${target_plan}"
                            printf '\n%s\n' "$new_plan_task" >> "$PLANQ_FILE"
                            echo "make-plan: Added 'plan: ${target_plan}' at end of queue."
                        fi
                    fi
                fi
                _auto_set_review_ready
                ;;
            underway)
                _mark_underway "$line_num" "$task_line"
                echo "Marked as underway."
                _auto_set_review_developing
                ;;
            inactive)         _mark_inactive        "$line_num" "$task_line"; echo "Marked as inactive (pending)." ;;
            queue)            _mark_auto_queue      "$line_num" "$task_line"; echo "Marked as auto-queue." ;;
            awaiting-commit)  _mark_awaiting_commit "$line_num" "$task_line"; echo "Marked as awaiting-commit." ;;
            awaiting-plan)    _mark_awaiting_plan   "$line_num" "$task_line"; echo "Marked as awaiting-plan." ;;
            deferred)         _mark_deferred        "$line_num" "$task_line"; echo "Marked as deferred." ;;
            auto-commit)      _set_commit_flag "$line_num" "auto-commit";  echo "Marked auto-commit." ;;
            stage-commit)     _set_commit_flag "$line_num" "stage-commit"; echo "Marked stage-commit." ;;
            manual-commit)    _set_commit_flag "$line_num" "manual-commit"; echo "Marked manual-commit." ;;
            no-commit)        _set_commit_flag "$line_num" "none";         echo "Cleared commit flag." ;;
        esac
    done
    _notify_daemon
}

_run_task_inline() {
    # Run a task (already stripped of status prefix) and mark it done.
    # $1 = line_num, $2 = task_line
    local line_num="$1" task_line="$2"
    local task_type task_value task_auto_commit task_stage_commit task_manual_commit task_add_after task_add_end task_auto_queue_plan
    _parse_task "$task_line"
    echo "Auto-running: $task_line"
    _mark_underway "$line_num" "$task_line"
    _auto_set_review_developing
    _notify_daemon

    case "$task_type" in
        task)
            local task_file="$PLANS_DIR/$task_value"
            if [ ! -f "$task_file" ]; then
                echo "Error: task file not found: $task_file" >&2
                _mark_inactive "$line_num" "$task_line"
                _notify_daemon
                return 1
            fi
            _invoke_claude "$(cat "$task_file") REQUIRED FINAL STEP: Write a brief summary of what you accomplished to plans/feedback-${task_value} (create this file even if brief). This summary appears in the project dashboard."
            ;;
        plan)
            _invoke_claude "Read plans/$task_value and implement the plan described in it. REQUIRED FINAL STEP: Write a brief summary of what you implemented to plans/feedback-${task_value} (create this file even if brief). This summary appears in the project dashboard."
            ;;
        make-plan)
            local prompt_file="$PLANS_DIR/$task_value"
            if [ ! -f "$prompt_file" ]; then
                echo "Error: prompt file not found: $prompt_file" >&2
                _mark_inactive "$line_num" "$task_line"
                _notify_daemon
                return 1
            fi
            local prompt target_plan
            prompt="$(cat "$prompt_file")"
            target_plan="${task_value/#make-plan-/plan-}"
            _invoke_claude "${prompt} Write the plan to plans/${target_plan}. REQUIRED FINAL STEP: Write a brief summary of the plan you created to plans/feedback-${task_value} (create this file even if brief). This summary appears in the project dashboard."
            if [ -n "$task_add_after" ] || [ -n "$task_add_end" ] || [ -n "$task_add_subtask" ]; then
                _mark_done "$line_num" "$task_line"
                local new_plan_task="- plan: ${target_plan}"
                [ -n "$task_auto_queue_plan" ] && new_plan_task="- [auto-queue] plan: ${target_plan}"
                if [ -n "$task_add_subtask" ]; then
                    local _raw_line
                    _raw_line="$(sed -n "${line_num}p" "$PLANQ_FILE" 2>/dev/null || echo "")"
                    local _depth=0 _indent="${_raw_line%%[! ]*}"
                    _depth=$(( ${#_indent} / 2 ))
                    local _child_indent
                    _child_indent="$(printf '%*s' $(( (_depth + 1) * 2 )) '')"
                    new_plan_task="${_child_indent}${new_plan_task}"
                    _insert_after_line "$line_num" "$new_plan_task"
                    echo "make-plan: Added 'plan: ${target_plan}' as subtask."
                elif [ -n "$task_add_after" ]; then
                    _insert_after_line "$line_num" "$new_plan_task"
                    echo "make-plan: Added 'plan: ${target_plan}' after current position."
                else
                    printf '\n%s\n' "$new_plan_task" >> "$PLANQ_FILE"
                    echo "make-plan: Added 'plan: ${target_plan}' at end of queue."
                fi
                _notify_daemon
                return 0
            else
                # Manual review — mark awaiting-plan and block auto-queue
                _mark_awaiting_plan "$line_num" "$task_line"
                echo "make-plan: Plan written to plans/${target_plan}. Add it to the queue to continue."
                _notify_daemon
                return 0
            fi
            ;;
        unnamed-task)
            _invoke_claude "$task_value"
            ;;
        auto-test)
            if ! _run_auto_test "$task_value"; then
                _mark_inactive "$line_num" "$task_line"
                _notify_daemon
                return 1
            fi
            ;;
        agent-test)
            _invoke_claude "$task_value"
            ;;
        auto-commit)
            if ! _run_auto_commit "$task_value"; then
                _mark_inactive "$line_num" "$task_line"
                _notify_daemon
                return 1
            fi
            ;;
        manual-test|manual-commit|manual-task)
            echo ""
            echo "━━━ Manual step required ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            printf "  Type: %s\n" "$task_type"
            if [[ "$task_value" == *.md ]] && [ -f "$PLANS_DIR/$task_value" ]; then
                printf "  File: plans/%s\n" "$task_value"
                echo "  ---"
                cat "$PLANS_DIR/$task_value" | sed 's/^/  /'
            else
                printf "  Task: %s\n" "$task_value"
            fi
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  Mark done in the dashboard, or run: planq mark done <task>"
            echo "  To cancel: planq mark inactive <task>"
            # Poll until the task is no longer underway (done or marked inactive from dashboard)
            while true; do
                sleep 3
                local ml_line
                ml_line="$(awk -v n="$line_num" 'NR == n { print; exit }' "$PLANQ_FILE" 2>/dev/null || true)"
                ml_line="${ml_line#"${ml_line%%[![:space:]]*}"}"
                [[ "$ml_line" == *"[underway]"* ]] || break
            done
            # If already marked done/inactive via dashboard, skip _mark_done below
            if [[ "$ml_line" != *"[underway]"* ]]; then
                _auto_set_review_ready
                _notify_daemon
                return 0
            fi
            ;;
        *)
            echo "Error: Unknown task type '$task_type' in: $task_line" >&2
            _mark_inactive "$line_num" "$task_line"
            _notify_daemon
            return 1
            ;;
    esac

    # If the task had +auto-commit, ask Claude to commit after completion
    if [ -n "$task_auto_commit" ] && [ "$task_type" != "auto-commit" ]; then
        _run_auto_commit "" || { _notify_daemon; return 1; }
    fi

    # If the task had +stage-commit, stage changes and mark awaiting-commit instead of done
    if [ -n "$task_stage_commit" ] && [ "$task_type" != "auto-commit" ]; then
        if _run_stage_commit ""; then
            _mark_awaiting_commit "$line_num" "$task_line"
            echo "stage-commit: changes staged. Commit when ready."
            _notify_daemon
            return 0
        else
            _notify_daemon; return 1
        fi
    fi

    # If the task had +manual-commit, mark awaiting-commit (user stages and commits manually)
    if [ -n "$task_manual_commit" ] && [ "$task_type" != "auto-commit" ]; then
        _mark_awaiting_commit "$line_num" "$task_line"
        echo "manual-commit: task complete. Stage and commit changes manually."
        _notify_daemon
        return 0
    fi

    _mark_done "$line_num" "$task_line"
    _auto_set_review_ready
    _notify_daemon
}

cmd_auto() {
    local auto_pid_file="$HOME/.local/devcontainer-sandbox/planq/planq-auto.pid"
    mkdir -p "$(dirname "$auto_pid_file")"

    # Warn if another auto session appears to be running
    if [ -f "$auto_pid_file" ]; then
        local other_pid
        other_pid="$(cat "$auto_pid_file" 2>/dev/null || true)"
        if [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null; then
            echo "Warning: Another auto session is already running (PID $other_pid)." >&2
            echo "Stop it first with: kill $other_pid" >&2
            return 1
        fi
    fi

    echo "$$" > "$auto_pid_file"
    echo "Auto-queue started (PID $$). Monitoring $PLANQ_FILE ..."
    echo "Press Ctrl+C to stop."
    echo ""

    # INT/TERM: print message and exit cleanly (single message, no double-fire).
    # EXIT: just remove the PID file (covers normal exits without double-printing).
    trap 'rm -f "$auto_pid_file"; echo ""; echo "Auto-queue stopped."; exit 0' INT TERM
    trap 'rm -f "$auto_pid_file"' EXIT

    # _PLANQ_CONTINUE: empty for first task (new session), "1" for subsequent tasks.
    # _invoke_claude() in _run_task_inline reads this to use --continue after the first.
    _PLANQ_CONTINUE=""

    local idle_msg_shown=0
    while true; do
        # Check for awaiting-plan tasks — they block auto-queue progression
        local awaiting_plan
        awaiting_plan="$(_find_next_awaiting_plan_task)"
        if [ -n "$awaiting_plan" ]; then
            idle_msg_shown=0
            local ap_line_num ap_task_line
            ap_line_num="$(printf '%s' "$awaiting_plan" | cut -f1)"
            ap_task_line="$(printf '%s' "$awaiting_plan" | cut -f2-)"
            _wait_for_plan "$ap_line_num" "$ap_task_line"
            continue
        fi

        # Check for awaiting-commit tasks — they block auto-queue progression
        local awaiting
        awaiting="$(_find_next_awaiting_commit_task)"
        if [ -n "$awaiting" ]; then
            idle_msg_shown=0
            local ac_line_num ac_task_line
            ac_line_num="$(printf '%s' "$awaiting" | cut -f1)"
            ac_task_line="$(printf '%s' "$awaiting" | cut -f2-)"
            _wait_for_stage_commit "$ac_line_num" "$ac_task_line"
            continue
        fi

        local next
        next="$(_find_next_auto_task)"
        if [ -z "$next" ]; then
            if [ "$idle_msg_shown" -eq 0 ]; then
                echo "No auto-queue tasks. Waiting... (mark tasks with: planq mark queue <N>)"
                idle_msg_shown=1
            fi
            sleep 5
            continue
        fi
        idle_msg_shown=0
        local line_num task_line
        line_num="$(printf '%s' "$next" | cut -f1)"
        task_line="$(printf '%s' "$next" | cut -f2-)"
        _run_task_inline "$line_num" "$task_line"
        _PLANQ_CONTINUE=1
    done
}

cmd_delete() {
    local task_num="${1:-}"
    if [ -z "$task_num" ]; then
        echo "Usage: planq delete <N>" >&2; return 1
    fi
    local next
    next="$(_find_task_by_identifier "$task_num")"
    if [ -z "$next" ]; then
        echo "No task #$task_num in $PLANQ_FILE" >&2; return 1
    fi
    local line_num task_line
    line_num="$(printf '%s' "$next" | cut -f1)"
    task_line="$(printf '%s' "$next" | cut -f2-)"
    echo "Deleting task #$task_num: $task_line"
    _delete_line "$line_num"
    echo "Deleted."
    _notify_daemon
}

cmd_archive() {
    local unarchive=""
    local identifiers=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --unarchive|-U) unarchive=1; shift ;;
            --help|-h) echo "Usage: planq archive [N...] [-U|--unarchive N]"; echo "  Archive done tasks (all if no args), or unarchive with -U."; return 0 ;;
            -*) echo "Unknown option: $1" >&2; echo "Usage: planq archive [N...] [-U|--unarchive N]" >&2; return 1 ;;
            *) identifiers+=("$1"); shift ;;
        esac
    done

    if [ -n "$unarchive" ]; then
        if [ ${#identifiers[@]} -eq 0 ]; then
            echo "Error: --unarchive requires task identifier(s)" >&2; return 1
        fi
        for ident in "${identifiers[@]}"; do
            local next
            next="$(_find_archive_by_identifier "$ident")"
            if [ -z "$next" ]; then
                echo "No matching archive entry '$ident' in $HISTORY_FILE" >&2
                continue
            fi
            local line_num task_line task_type task_value
            line_num="$(printf '%s' "$next" | cut -f1)"
            task_line="$(printf '%s' "$next" | cut -f2-)"
            _parse_task "$task_line"

            if [ "$task_type" = "task" ] || [ "$task_type" = "plan" ] || [ "$task_type" = "make-plan" ]; then
                if [ -f "$ARCHIVE_DIR/$task_value" ]; then
                    mv "$ARCHIVE_DIR/$task_value" "$PLANS_DIR/$task_value"
                    echo "  Moved: plans/archive/$task_value → plans/$task_value"
                fi
            fi

            # Read original line (with status prefix) from history before removing
            local original_line
            original_line="$(awk -v n="$line_num" 'NR == n { print; exit }' "$HISTORY_FILE")"
            original_line="${original_line#"${original_line%%[![:space:]]*}"}"

            local tmp
            tmp="$(mktemp)"
            awk -v n="$line_num" 'NR != n { print }' "$HISTORY_FILE" > "$tmp"
            mv "$tmp" "$HISTORY_FILE"

            mkdir -p "$(dirname "$PLANQ_FILE")"
            printf '%s\n' "$original_line" >> "$PLANQ_FILE"
            echo "Unarchived: $task_line"
        done
        _notify_daemon
        return
    fi

    if [ ! -f "$PLANQ_FILE" ]; then
        echo "(no planq file at $PLANQ_FILE)"
        return
    fi

    if [ ${#identifiers[@]} -gt 0 ]; then
        local tmp_tasks
        tmp_tasks="$(mktemp)"
        for ident in "${identifiers[@]}"; do
            local next
            next="$(_find_task_by_identifier "$ident")"
            if [ -z "$next" ]; then
                echo "No matching task '$ident' in planq" >&2
                continue
            fi
            local line_num task_line depth
            line_num="${next%%	*}"
            task_line="${next#*	}"
            _content_depth_step "$task_line"
            if [ "$depth" -gt 0 ]; then
                echo "Error: '$task_line' is a subtask — archive its parent task instead" >&2
                continue
            fi
            printf '%s\n' "$next" >> "$tmp_tasks"
            _get_subtasks "$line_num" >> "$tmp_tasks"
        done
    else
        local tmp_tasks
        tmp_tasks="$(mktemp)"
        local n=0
        while IFS= read -r line; do
            n=$((n + 1))
            local trimmed="${line#"${line%%[![:space:]]*}"}"
            [ -z "$trimmed" ] && continue
            [[ "$line" == "#"* ]] && continue
            local after_dash="${line#*"- "}" _v2_status depth
            _v2_extract_status "$after_dash"
            if [ "$_v2_status" = "done" ]; then
                _content_depth_step "$line"
                # Only collect top-level done tasks; subtasks are added by _get_subtasks
                if [ "$depth" -eq 0 ]; then
                    printf '%d\t%s\n' "$n" "$line" >> "$tmp_tasks"
                    _get_subtasks "$n" >> "$tmp_tasks"
                fi
            fi
        done < "$PLANQ_FILE"
    fi

    if [ ! -s "$tmp_tasks" ]; then
        rm -f "$tmp_tasks"
        echo "No done tasks to archive."
        return
    fi

    # Write history in forward order (parent before subtasks), then delete in reverse
    # (reverse deletion preserves line number validity as higher lines are removed first)
    while IFS=$'\t' read -r line_num task_line; do
        echo "Archiving: $task_line"
        _archive_one_task "$line_num" "$task_line" "history"
    done < <(sort -t$'\t' -k1 -n "$tmp_tasks")
    while IFS=$'\t' read -r line_num task_line; do
        _archive_one_task "$line_num" "$task_line" "delete"
    done < <(sort -t$'\t' -k1 -rn "$tmp_tasks")
    rm -f "$tmp_tasks"
    _notify_daemon
}

_write_test_result() {
    local task_line="$1" result="$2" notes="${3:-}"
    local results_dir="$WORKSPACE_ROOT/.claude/test-results"
    mkdir -p "$results_dir"
    # Derive slug from task description: first 40 chars, lowercase, spaces→hyphens, strip non-alphanumeric
    local task_desc
    task_desc="$(echo "$task_line" | sed 's/^[^:]*: //' | cut -c1-40)"
    local slug
    slug="$(echo "$task_desc" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')"
    [ -z "$slug" ] && slug="task-$(date -u +%s)"
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local result_file="$results_dir/${slug}.json"
    printf '{\n  "task": %s,\n  "result": %s,\n  "notes": %s,\n  "timestamp": %s\n}\n' \
        "$(echo "$task_line" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')" \
        "$(echo "$result"    | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')" \
        "$(echo "$notes"     | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')" \
        "$(echo "$timestamp" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')" \
        > "$result_file"
    echo "Test result recorded: $result ($result_file)"
}

cmd_review() {
    local subcmd="${1:-status}"
    shift || true
    local state_file="$WORKSPACE_ROOT/.claude/review-state"
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    case "$subcmd" in
        developing|ready-for-review|in-review|approved|merged)
            mkdir -p "$(dirname "$state_file")"
            {
                echo "state: $subcmd"
                echo "updated: $timestamp"
            } > "$state_file"
            echo "Review state set to: $subcmd"
            _notify_daemon
            ;;
        notes)
            local notes="${*:-}"
            [ -z "$notes" ] && { echo "Usage: planq review notes <text>" >&2; return 1; }
            if [ -f "$state_file" ]; then
                local tmpf
                tmpf="$(mktemp)"
                grep -v "^notes:" "$state_file" > "$tmpf" || true
                echo "notes: $notes" >> "$tmpf"
                mv "$tmpf" "$state_file"
            else
                mkdir -p "$(dirname "$state_file")"
                { echo "state: developing"; echo "updated: $timestamp"; echo "notes: $notes"; } > "$state_file"
            fi
            echo "Review notes updated"
            _notify_daemon
            ;;
        status)
            if [ -f "$state_file" ]; then
                echo "Review state for $WORKSPACE_ROOT:"
                cat "$state_file"
            else
                echo "No review state set for $WORKSPACE_ROOT (default: developing)"
            fi
            ;;
        *)
            echo "Usage: planq review <developing|ready-for-review|in-review|approved|merged|notes <text>|status>" >&2
            return 1
            ;;
    esac
}

cmd_set_review() {
    local ident="${1:-}"
    local status="${2:-}"
    if [ -z "$ident" ] || [ -z "$status" ]; then
        echo "Usage: planq task-review <filename-or-N> <status>" >&2
        echo "  status: none|ready|testing|passed|has-issues|fix-scheduled|follow-up|revert-scheduled|ready-for-merge|merged|cancelled|retry-later" >&2
        return 1
    fi
    case "$status" in
        none|ready|testing|passed|has-issues|fix-scheduled|follow-up|revert-scheduled|ready-for-merge|merged|cancelled|retry-later) ;;
        *) echo "Invalid review status: $status" >&2; return 1 ;;
    esac

    local next
    next="$(_find_task_by_identifier "$ident")"
    if [ -z "$next" ]; then
        echo "No matching task for '$ident' in $PLANQ_FILE" >&2; return 1
    fi

    local task_line task_type task_value task_auto_commit task_stage_commit task_manual_commit task_add_after task_add_end task_auto_queue_plan
    task_line="$(printf '%s' "$next" | cut -f2-)"
    _parse_task "$task_line"

    if [ -z "$task_value" ] || [ "$task_type" = "unnamed-task" ]; then
        echo "Task has no file; review status only applies to file-based tasks" >&2; return 1
    fi

    local task_file="$PLANS_DIR/$task_value"
    if [ ! -f "$task_file" ]; then
        echo "Task file not found: $task_file" >&2; return 1
    fi

    local tmpf
    tmpf="$(mktemp)"
    if grep -q "^review:" "$task_file"; then
        sed "s/^review:.*$/review: $status/" "$task_file" > "$tmpf" || { rm -f "$tmpf"; echo "Failed to update file" >&2; return 1; }
    else
        cat "$task_file" > "$tmpf"
        printf '\nreview: %s\n' "$status" >> "$tmpf"
    fi
    mv "$tmpf" "$task_file" || { echo "Failed to write file" >&2; return 1; }
    echo "Review status set to '$status' for: $task_value"
    _notify_daemon
}

# ── Profile management ────────────────────────────────────────────────────────

_PROFILES_JSON="${HOME}/.local/devcontainer-sandbox/profiles.json"
_ACTIVE_PROFILE_FILE="${WORKSPACE_ROOT:-.}/.devcontainer/.active-profile"

_read_profiles_json() {
    if [ ! -f "$_PROFILES_JSON" ]; then
        echo "No profiles.json at $_PROFILES_JSON" >&2
        echo "Copy profiles.json.example from the devcontainer-sandbox repo to that path." >&2
        return 1
    fi
    cat "$_PROFILES_JSON"
}

cmd_profiles() {
    local subcmd="${1:-list}"
    shift 2>/dev/null || true

    case "$subcmd" in
        list)
            local json
            json="$(_read_profiles_json)" || return 1
            echo "Profiles (from $_PROFILES_JSON):"
            echo ""
            echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
profiles = data.get('profiles', {})
defaults = data.get('defaults', {})
primary = defaults.get('primary_profile', '')
chain = defaults.get('fallback_chain', [])
for name, p in profiles.items():
    flags = []
    if name == primary: flags.append('primary')
    if name in chain: flags.append(f'fallback #{chain.index(name)+1}')
    flag_str = f'  ({', '.join(flags)})' if flags else ''
    print(f'  {name:15s} {p.get(\"type\",\"?\"):25s} {p.get(\"description\",\"\")}{flag_str}')
print()
print(f'Default: {primary}')
print(f'Fallback chain: {\" → \".join(chain)}')
" 2>/dev/null || echo "$json" | python3 -c "import sys,json; [print(f'  {k}: {v.get(\"type\",\"?\")}') for k,v in json.load(sys.stdin).get('profiles',{}).items()]"
            echo ""
            local active
            active="$(cat "$_ACTIVE_PROFILE_FILE" 2>/dev/null)" || true
            echo "Active profile in this container: ${active:-<not set — using CCS default>}"
            ;;

        active)
            local active
            active="$(cat "$_ACTIVE_PROFILE_FILE" 2>/dev/null)" || true
            echo "${active:-<not set>}"
            ;;

        switch)
            local profile="${1:-}"
            if [ -z "$profile" ]; then
                echo "Usage: planq profiles switch <profile-name>" >&2
                return 1
            fi
            # Validate profile exists in profiles.json
            local json
            json="$(_read_profiles_json)" || return 1
            if ! echo "$json" | python3 -c "import sys,json; p=json.load(sys.stdin).get('profiles',{}); sys.exit(0 if '$profile' in p else 1)" 2>/dev/null; then
                echo "Error: profile '$profile' not found in $_PROFILES_JSON" >&2
                echo "Available: $(echo "$json" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('profiles',{}).keys()))")" >&2
                return 1
            fi
            mkdir -p "$(dirname "$_ACTIVE_PROFILE_FILE")"
            echo "$profile" > "$_ACTIVE_PROFILE_FILE"
            echo "Switched to profile: $profile"
            echo "The next ccs session will use this profile."
            _notify_daemon
            ;;

        init)
            local target_profile="${1:-}"
            local json
            json="$(_read_profiles_json)" || return 1
            echo "$json" | python3 -c "
import sys, json, subprocess
data = json.load(sys.stdin)
profiles = data.get('profiles', {})
target = '$target_profile'
for name, p in profiles.items():
    if target and name != target:
        continue
    ptype = p.get('type', '')
    print(f'Setting up profile: {name} ({ptype})')
    if ptype in ('claude-subscription', 'claude-api'):
        print(f'  Run: ccs auth create {name}')
        print(f'  (Interactive — authenticate in browser or enter API key)')
    elif ptype == 'openai-compatible':
        base_url = p.get('baseUrl', '')
        model = p.get('model', '')
        print(f'  Provider: {p.get(\"provider\",\"?\")} / Model: {model}')
        print(f'  Base URL: {base_url}')
        print(f'  Configure: ~/.ccs/{name}.settings.json with your API key')
    print()
"
            echo "Run the commands above to complete profile setup."
            echo "For subscription profiles, ccs auth create will open a browser for OAuth."
            ;;

        --help|-h|help)
            echo "Usage: planq profiles <list|active|switch|init> [args]"
            echo ""
            echo "Commands:"
            echo "  list                  Show all profiles from profiles.json"
            echo "  active                Show the current container's active profile"
            echo "  switch <name>         Switch active profile for this container"
            echo "  init [--profile name] Show setup instructions for all/one profile(s)"
            echo ""
            echo "Profile registry: $_PROFILES_JSON"
            echo "Active profile marker: $_ACTIVE_PROFILE_FILE"
            ;;

        *)
            echo "Unknown profiles subcommand: $subcmd" >&2
            echo "Run: planq profiles --help" >&2
            return 1
            ;;
    esac
}

cmd_daemon() {
    local daemon_sh="$SCRIPT_DIR/planq-daemon.sh"
    if [ ! -x "$daemon_sh" ]; then
        echo "Error: planq-daemon.sh not found at $daemon_sh" >&2
        exit 1
    fi
    "$daemon_sh" "${1:-status}" "${@:2}"
}

cmd_logs() {
    _has_help_flag "$@" && { usage_logs; return 0; }
    local log_file="$HOME/.local/devcontainer-sandbox/logs/planq-daemon.log"
    local do_cat=0 do_follow=0 lines=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -c)       do_cat=1; shift ;;
            -f)       do_follow=1; shift ;;
            -n)       lines="${2:?'-n requires a number'}"; shift 2 ;;
            -n*)      lines="${1#-n}"; shift ;;
            --help|-h) usage_logs; return 0 ;;
            *) echo "Unknown option: $1" >&2; usage_logs >&2; exit 1 ;;
        esac
    done
    if [ ! -f "$log_file" ]; then
        echo "Log file not found: $log_file" >&2
        exit 1
    fi
    if [ "$do_cat" -eq 1 ]; then
        cat "$log_file"
    elif [ "$do_follow" -eq 1 ]; then
        tail -f ${lines:+-n "$lines"} "$log_file"
    else
        tail ${lines:+-n "$lines"} "$log_file"
    fi
}

usage_list() {
    echo "Usage: planq list [-a|--archive] [-r|--remaining] [-f <filter>|--filter:<filter>]"
    echo "  List all tasks with status."
    echo "  -a, --archive        Show archived tasks instead of active queue"
    echo "  -r, --remaining      Hide done tasks (shorthand for -f -done)"
    echo "  -f, --filter <expr>  Filter by status (e.g. done, -done, underway, auto-queue)"
    echo "  -f:<expr>            Short form (e.g. -f:underway)"
}
usage_show()   { echo "Usage: planq show [-a|--archive] [N]"; echo "  Show the next pending task, or task #N if given. Use -a for archive entries."; }
usage_archive() {
    echo "Usage: planq archive [N|filename|text ...]"
    echo "       planq archive --unarchive|-U <N|filename|text> ..."
    echo "  Archive done tasks, removing them from the planq and appending to plans/archive/planq-history.txt."
    echo "  With no arguments: archives all done tasks."
    echo "  With identifiers: archives specific tasks (by number, filename, or text)."
    echo "  Associated task files are moved to plans/archive/."
    echo "  --unarchive/-U: restore archived tasks back to the planq."
}
usage_run()    { echo "Usage: planq run [N] [--dry-run|-n]"; echo "  Run the next pending task, or task #N if given, then mark it done."; }
cmd_follow_up() {
    # follow-up / fu [-p <parent>] [parent] [OPTIONS] [desc]  — create subtask
    # fixup    / fx [-p <parent>] [parent] [OPTIONS] [desc]  — same but with link-type fix-required
    # Flags: -r/--run (mark underway), -q/--queue (auto-queue), -n/--no-run (just create, default)
    # Parent can be specified with -p/--parent or as first non-flag positional arg.
    local default_link_type="${1:-follow-up}"
    shift

    local parent="" task_type="unnamed-task" filename="" description="" link_type="$default_link_type"
    local run_mode="no-run"  # default: just create
    local rest_args=("$@")
    local create_args=()
    local i=0
    while [ $i -lt ${#rest_args[@]} ]; do
        case "${rest_args[$i]}" in
            --run|-r)  run_mode="run"; i=$((i+1)) ;;
            --no-run|-n) run_mode="no-run"; i=$((i+1)) ;;
            --queue|-q) run_mode="queue"; i=$((i+1)) ;;
            --parent|-p) parent="${rest_args[$((i+1))]:-}"; i=$((i+2)) ;;
            --type|-t) task_type="${rest_args[$((i+1))]:-}"; create_args+=("${rest_args[$i]}" "${rest_args[$((i+1))]:-}"); i=$((i+2)) ;;
            --file|-f) filename="${rest_args[$((i+1))]:-}"; create_args+=("${rest_args[$i]}" "${rest_args[$((i+1))]:-}"); i=$((i+2)) ;;
            --slug|-s) create_args+=("${rest_args[$i]}" "${rest_args[$((i+1))]:-}"); i=$((i+2)) ;;
            --link-type|-l) link_type="${rest_args[$((i+1))]:-}"; create_args+=("${rest_args[$i]}" "${rest_args[$((i+1))]:-}"); i=$((i+2)) ;;
            --auto-commit|--stage-commit|--manual-commit|--add-after|--add-end|--add-subtask|--auto-queue-plan)
                create_args+=("${rest_args[$i]}"); i=$((i+1)) ;;
            --help|-h) usage_followup; return 0 ;;
            *)
                # First non-flag positional with no parent yet → interpret as parent
                if [ -z "$parent" ] && [[ "${rest_args[$i]}" =~ ^[0-9.]+$ || "${rest_args[$i]}" == *.md ]]; then
                    parent="${rest_args[$i]}"; i=$((i+1))
                else
                    if [ -z "$description" ]; then description="${rest_args[$i]}"; else description="$description ${rest_args[$i]}"; fi
                    create_args+=("${rest_args[$i]}"); i=$((i+1))
                fi
                ;;
        esac
    done

    if [ -z "$parent" ]; then
        echo "Error: parent task required (e.g. planq follow-up 3 'Fix the bug' or planq fu -r -p 3 'Fix')" >&2
        return 1
    fi

    # Normalize filename like cmd_create does
    if [ -n "$filename" ]; then
        case "$filename" in *.md) ;; *) filename="${filename}.md" ;; esac
        case "$task_type" in
            task|plan|make-plan|investigate|manual-test|manual-commit|manual-task)
                case "$filename" in
                    ${task_type}-*) ;;
                    *) filename="${task_type}-${filename}" ;;
                esac ;;
        esac
    fi

    # Create the subtask under the parent
    # Capture output to extract actual identifier (handles auto-generated filenames and
    # type inference for -f without -t).
    local create_out
    create_out="$(cmd_create -p "$parent" -l "$link_type" "${create_args[@]}" 2>&1)" || { printf '%s\n' "$create_out" >&2; return 1; }
    printf '%s\n' "$create_out"

    # Extract identifier from "Created subtask (...): TYPE: VALUE [+flags]" output line
    local created_line ident
    created_line="$(printf '%s\n' "$create_out" | grep '^Created subtask ' | head -1)"
    if [ -n "$created_line" ]; then
        local after_paren="${created_line##*): }"   # "TYPE: VALUE [+flags]"
        ident="${after_paren#*: }"                   # "VALUE [+flags]"
        ident="${ident%% +*}"                        # strip trailing flags
    fi

    if [ -z "$ident" ]; then
        echo "Warning: could not determine task identifier" >&2
        return 0
    fi

    # Apply the requested run mode
    local task_info line_num task_line
    task_info="$(_find_task_by_identifier "$ident")" || true
    if [ -z "$task_info" ]; then
        echo "Warning: could not find created task '$ident'" >&2
        return 0
    fi
    line_num="${task_info%%	*}"
    task_line="${task_info#*	}"

    case "$run_mode" in
        run)
            _mark_underway "$line_num" "$task_line"
            _notify_daemon
            echo "Marked underway: $task_line"
            ;;
        queue)
            _mark_auto_queue "$line_num" "$task_line"
            _notify_daemon
            echo "Queued: $task_line"
            ;;
        no-run)
            local _fu_num
            _fu_num="$(_get_dotted_number_for_line "$line_num")"
            echo "Created #${_fu_num}: $task_line"
            ;;
    esac
}

usage_follow_up() {
    echo "Usage: planq follow-up [-p <parent>] [<parent>] [-r|-n|-q] [-t <type>] [-f <file>] [-s <slug>] [-l <link-type>] [<desc>]"
    echo "       planq fixup    [-p <parent>] [<parent>] [-r|-n|-q] [-t <type>] [-f <file>] [-s <slug>] [-l <link-type>] [<desc>]"
    echo "  Create a subtask under <parent>."
    echo "  follow-up / fu  default link type: follow-up"
    echo "  fixup     / fx  default link type: fix-required"
    echo "  <parent>        Parent task number, filename, or description text"
    echo ""
    echo "  Run mode (default: -n / --no-run):"
    echo "    -r, --run      Mark underway immediately (for inline execution by /planq)"
    echo "    -n, --no-run   Just create the task (default from CLI / planq shell)"
    echo "    -q, --queue    Mark as auto-queued for the next auto-run"
    echo ""
    echo "  Accepts same options as 'planq create' (see planq create --help)"
    echo ""
    echo "  Examples:"
    echo "    planq follow-up 3 'Check output format after refactor'"
    echo "    planq fu 3 -r -t task -f task-fix-login.md 'Fix login regression'"
    echo "    planq fixup 3 -q 'Fix the crash in error handler'"
    echo "    planq fx 5 -l check 'Verify edge case X'"
    echo ""
    echo "  From /planq (agent), -r is the default.  From CLI/shell, -n is the default."
}

usage_create() {
    echo "Usage: planq create [-t <type>] [-f <file>] [-s <slug>] [-p <parent>] [-l <link-type>] [-q] [<desc>]"
    echo "  Add a task to the planq file."
    echo "  -t, --type       Task type (default: unnamed-task)"
    echo "  -f, --file       Filename in plans/ (required for task/plan/make-plan/investigate types)"
    echo "  -s, --slug       Short slug — generates filename as \$type-\$slug.md (type defaults to task)"
    echo "  -p, --parent     Parent task number or filename — creates a subtask inserted after the parent"
    echo "  -l, --link-type  Link type for subtasks: follow-up (default), fix-required, check, or other"
    echo "  --auto-commit    After task: Claude commits automatically"
    echo "  --stage-commit   After task: Claude stages + drafts message, task pauses for user to commit"
    echo "  --manual-commit  After task: task pauses at awaiting-commit (user stages and commits manually)"
    echo "  -q, --queue      Mark the created task as auto-queued immediately"
    echo "  Task types: unnamed-task (default), task, plan, make-plan, investigate, auto-test, auto-commit, manual-test, manual-commit, manual-task, agent-test"
    echo ""
    echo "  For make-plan, -f specifies the prompt filename (make-plan-*.md); Claude writes plan-*.md:"
    echo "    planq create -t make-plan -f make-plan-001.md 'Design a caching layer for the API'"
    echo ""
    echo "  For investigate, -f specifies the prompt filename (investigate-*.md); Claude writes feedback-*.md:"
    echo "    planq create -t investigate -f investigate-perf.md 'Why is the API slow under load?'"
    echo ""
    echo "  Subtask examples:"
    echo "    planq create -p 3 'Fix the login bug found during review'   # unnamed follow-up subtask after task #3"
    echo "    planq create -p parent.md -l fix-required -t task -f fix-login.md  # file-based fix-required subtask"
    echo "    planq create -p 3 -l check 'Verify the output format'  # check subtask"
    echo "    planq create -p 3 -l other 'Related cleanup'  # other relationship"
}
usage_mark()   {
    echo "Usage: planq mark <state> <N|filename|text>"
    echo "       planq mark:<state> <N|filename|text>"
    echo "  Mark a task with a status or commit flag."
    echo "  Identify the task by number, by its filename (for task/plan/make-plan), or by its exact description text (for unnamed-task etc.)."
    echo ""
    echo "  Status states:"
    echo "  done/d              mark task done"
    echo "  underway/u          mark task in-progress"
    echo "  inactive/i          restore done/underway/auto-queue/awaiting-commit task to pending"
    echo "  queue/q/auto-queue/aq  mark for automatic execution by 'planq auto'"
    echo "  awaiting-commit/ac  mark as waiting for user to commit staged changes"
    echo "  awaiting-plan/ap    mark make-plan task as waiting for plan review"
    echo "  deferred/df         move task to the bottom of the list (skip for now)"
    echo ""
    echo "  Commit flags (modifies the +commit tag on the task line):"
    echo "  auto-commit/+ac     Claude commits automatically after task completes"
    echo "  stage-commit/+sc/sc Claude stages changes; task pauses for user to commit"
    echo "  manual-commit/+mc/mc task pauses at awaiting-commit (user stages/commits manually)"
    echo "  no-commit/+nc/nc    clear any commit flag"
}
usage_auto()   {
    echo "Usage: planq auto"
    echo "  Monitor the queue for tasks with auto-queue status and run them one at a time."
    echo "  Polls for new auto-queue tasks after each run. Press Ctrl+C to stop."
    echo "  Mark tasks for auto-execution with: planq mark queue <N>"
    echo "  Warns if another auto session is already running."
}
usage_delete() { echo "Usage: planq delete <N>"; echo "  Delete task #N from the planq file."; }
usage_daemon() { echo "Usage: planq daemon [start|stop|restart|status]"; echo "  Manage the planq WebSocket daemon (default: status)."; }
usage_logs()   {
    echo "Usage: planq logs [-c] [-f] [-n <N>]"
    echo "  Show the planq daemon log file."
    echo "  -c        Cat the whole log file."
    echo "  -f        Follow the log (tail -f)."
    echo "  -n <N>    Show last N lines (default: tail default)."
    echo "  With no options: tail the last 10 lines."
}

usage() {
    echo "Usage: planq.sh <subcommand> [options]"
    echo ""
    echo "Subcommands:"
    echo "  list    / l [-a] [-r] [-f <filter>]              List all tasks with status"
    echo "  show    / s [-a] [N]                            Show next pending task, or task #N"
    echo "  run     / r [N] [--dry-run|-n]                 Run next pending task, or task #N"
    echo "  auto    / A                                    Run auto-queued tasks continuously"
    echo "  create    / c  [-t <type>] [-f <file>] [-p <parent>] [-q] [<desc>]  Add a task or subtask (default type: unnamed-task)
  do        / do [-t <type>] [-f <file>] [-p <parent>] [<desc>]  Create a task and immediately run it"
    echo "  follow-up / fu <parent> [opts] [<desc>]  Create follow-up subtask (-r to run, -q to queue)"
    echo "  fixup     / fx <parent> [opts] [<desc>]  Create fix-required subtask (-r to run, -q to queue)"
    echo "  mark    / m <d|u|i|q|ac|ap|df|+ac|sc|mc|nc> <N|…>  Mark a task status or commit flag (also: mark:<state>)"
    echo "  delete  / x <N>                                Delete task #N"
    echo "  archive / a [N|…] [--unarchive|-U <N|…>]      Archive done tasks; -a flag on list/show for archive"
    echo "  profiles  <list|active|switch|init>             Manage agent profiles (CCS/OpenCode)"
    echo "  daemon  / d [start|stop|restart|status]        Manage the planq WebSocket daemon"
    echo "  logs    / L [-c] [-f] [-n <N>]                Show daemon log (default: tail)"
    echo "  worktree-review / wr <state|notes <text>|status>  Set/show worktree-level review state"
    echo "  task-review     / tr <N|file> <status>            Set task-level review status (none|ready|testing|passed|has-issues|fix-scheduled|follow-up|revert-scheduled|ready-for-merge|merged|cancelled|retry-later)"
    echo "  shell   / sh                                   Interactive planq REPL"
    echo ""
    echo "Task types:"
    echo "  unnamed-task               Pass description directly to claude as a prompt (default)"
    echo "  task                       Read plans/<file> and pass its contents to claude"
    echo "  plan                       Ask claude to read and implement plans/<file>"
    echo "  make-plan                  Use a prompt file (make-plan-*.md) to create a plan file (plan-*.md)"
    echo "  investigate                Research a question (investigate-*.md) and write findings (feedback-*.md)"
    echo "  auto-test                  Run a shell command as an automated test"
    echo "  auto-commit                Ask Claude to commit current changes"
    echo "  manual-(test|commit|task)  Pause for a manual step"
    echo "  agent-test                 Invoke Claude with description as a testing prompt"
    echo ""
    echo "Task line formats in planq file:"
    echo "  unnamed-task: <text>"
    echo "  task: <file>"
    echo "  plan: <file>"
    echo "  make-plan: <make-plan-file>  (prompt in plans/make-plan-*.md; Claude writes plans/plan-*.md)"
    echo "  investigate: <investigate-file>  (prompt in plans/investigate-*.md; findings in plans/feedback-*.md)"
    echo "  auto-test: <shell command>"
    echo "  auto-commit: <options>"
    echo "  manual-test: <desc>  (or manual-commit / manual-task)"
    echo "  agent-test: <desc>"
    echo ""
    echo "Planq file: $PLANQ_FILE"
}

_has_help_flag() {
    for arg in "$@"; do
        [ "$arg" = "--help" ] || [ "$arg" = "-h" ] && return 0
    done
    return 1
}

SUBCMD="${1:-}"
shift || true

# --help anywhere on the command line: show command-specific help if command is valid,
# otherwise show general usage.
if _has_help_flag "$@"; then
    case "$SUBCMD" in
        list|l)      usage_list ;;
        show|s)      usage_show ;;
        run|r)       usage_run ;;
        auto|A)      usage_auto ;;
        create|c)           usage_create ;;
        do)                 usage_create ;;
        follow-up|fu|fixup|fx) usage_follow_up ;;
        mark|m|mark:*|m:*) usage_mark ;;
        delete|x)    usage_delete ;;
        archive|a)   usage_archive ;;
        profiles)    cmd_profiles --help ;;
        daemon|d)    usage_daemon ;;
        *)           usage ;;
    esac
    exit 0
fi

case "$SUBCMD" in
    list|l)              cmd_list "$@" ;;
    show|s)              cmd_show "$@" ;;
    run|r)               cmd_run "$@" ;;
    auto|A)              cmd_auto "$@" ;;
    create|c)            cmd_create "$@" ;;
    do)                  cmd_do "$@" ;;
    follow-up|fu)        cmd_follow_up "follow-up" "$@" ;;
    fixup|fx)            cmd_follow_up "fix-required" "$@" ;;
    mark|m)              cmd_mark "$@" ;;
    mark:*|m:*)          cmd_mark "${SUBCMD#*:}" "$@" ;;
    delete|x)            cmd_delete "$@" ;;
    archive|a)           cmd_archive "$@" ;;
    profiles)            cmd_profiles "$@" ;;
    daemon|d)            cmd_daemon "$@" ;;
    logs|L)              cmd_logs "$@" ;;
    worktree-review|wr)  shift; cmd_review "$@" ;;
    task-review|tr)      shift; cmd_set_review "$@" ;;
    shell|sh)            exec bash "$SCRIPT_DIR/planq-shell.sh" "$@" ;;
    --help|-h|help|"")   usage ;;
    *)
        echo "Unknown subcommand: $SUBCMD" >&2
        echo ""
        usage
        exit 1
        ;;
esac
