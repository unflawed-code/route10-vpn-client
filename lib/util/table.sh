#!/bin/sh
# Route10 Table Utility
# Provides robust table alignment with emoji support and percentage-based columns

# ──────────────────────────────────────────────────────────────────────
# Percentage-based table API
#
# Usage:
#   tbl_init [total_width] [col1_pct] [col2_pct]
#   tbl_top
#   tbl_row "left" "right"
#   tbl_divider
#   tbl_bottom
#
# Example:
#   tbl_init 100 25 75
#   tbl_top
#   tbl_row "-c, --conf" "Path to WireGuard .conf file"
#   tbl_bottom
# ──────────────────────────────────────────────────────────────────────

# Internal state (set by tbl_init, guarded to survive re-sourcing)
_TBL_TOTAL="${_TBL_TOTAL:-100}"
_TBL_C1="${_TBL_C1:-25}"
_TBL_C2="${_TBL_C2:-75}"
_TBL_B1="${_TBL_B1:-27}"
_TBL_B2="${_TBL_B2:-75}"

# Initialize table dimensions from percentages.
# Args: $1=total_width (default 100)  $2=col1_pct  $3=col2_pct
# The total_width is the total number of characters between the outer │ borders,
# excluding the outer borders themselves.
# Each column's border width = content_width + 2 (for " " padding each side).
# Layout: │<padding><col1><padding>│<padding><col2><padding>│
#   = 1 + (1 + c1 + 1) + 1 + (1 + c2 + 1) + 1  but we only count inner width.
# Inner width = (c1 + 2) + 1 + (c2 + 2) = c1 + c2 + 5
# So: c1 + c2 = total_width - 5
tbl_init() {
    _TBL_TOTAL="${1:-100}"
    local pct1="${2:-25}"
    local pct2="${3:-75}"
    local usable=$((_TBL_TOTAL - 5))

    _TBL_C1=$((usable * pct1 / 100))
    _TBL_C2=$((usable - _TBL_C1))

    # Border widths include " " padding on each side
    _TBL_B1=$((_TBL_C1 + 2))
    _TBL_B2=$((_TBL_C2 + 2))
}

# Repeat a character N times
_tbl_repeat() {
    local char="$1"
    local count="$2"
    local out=""
    local i=0
    while [ "$i" -lt "$count" ]; do
        out="${out}${char}"
        i=$((i + 1))
    done
    printf "%s" "$out"
}

# Print table top border: ┌───┬───┐
tbl_top() {
    local l=$(_tbl_repeat "─" "$_TBL_B1")
    local r=$(_tbl_repeat "─" "$_TBL_B2")
    echo "┌${l}┬${r}┐"
}

# Print table bottom border: └───┴───┘
tbl_bottom() {
    local l=$(_tbl_repeat "─" "$_TBL_B1")
    local r=$(_tbl_repeat "─" "$_TBL_B2")
    echo "└${l}┴${r}┘"
}

# Print mid-table divider: ├───┼───┤
tbl_divider() {
    local l=$(_tbl_repeat "─" "$_TBL_B1")
    local r=$(_tbl_repeat "─" "$_TBL_B2")
    echo "├${l}┼${r}┤"
}

# Print a table row: │ left │ right │
# Args: $1=left_text  $2=right_text
tbl_row() {
    local left="$1"
    local right="$2"
    printf "│ %-${_TBL_C1}s │ %-${_TBL_C2}s │\n" "$left" "$right"
}

# ──────────────────────────────────────────────────────────────────────
# Legacy API (backward compat for ovpn.sh ASCII-style tables)
# ──────────────────────────────────────────────────────────────────────

# Get visual width of a string (compensating for emojis)
get_visual_width() {
    local str="$1"
    local extra=0

    # Check for specific emojis using case (fast and robust)
    case "$str" in *🔗*) extra=$((extra + 2)) ;; esac
    case "$str" in *🛡️*) extra=$((extra + 5)) ;; esac
    case "$str" in *🌐*) extra=$((extra + 2)) ;; esac
    case "$str" in *❌*) extra=$((extra + 1)) ;; esac
    case "$str" in *✅*) extra=$((extra + 1)) ;; esac
    case "$str" in *⏳*) extra=$((extra + 1)) ;; esac
    case "$str" in *⏱️*) extra=$((extra + 4)) ;; esac
    case "$str" in *⚠️*) extra=$((extra + 4)) ;; esac

    echo "$extra"
}

# Print a table row with emoji-aware alignment
print_table_row() {
    local label="$1"
    local value="$2"
    local val_width="${3:-50}"
    local label_width=16

    local extra=$(get_visual_width "$value")
    # Ensure extra is a number
    : "${extra:=0}"
    local pad=$((val_width + extra))

    # Format string construction for ash compatibility
    # If pad is empty or 0, it defaults to val_width which is fine
    printf "| %-${label_width}s | %-${pad}s |\n" "$label" "$value" || true
}

# Print a header row
print_table_header() {
    local text="$1"
    local total_width=69

    local extra=$(get_visual_width "$text")
    : "${extra:=0}"
    local pad=$((total_width + extra))

    printf "| %-${pad}s |\n" "$text" || true
}