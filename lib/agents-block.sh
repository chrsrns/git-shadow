#!/usr/bin/env bash
# -------------------------------------------------------------------
# Library: agents-block.sh
# Purpose: install and refresh the managed git-shadow block inside a
#          repo's AGENTS.local.md. The block is delimited by whole-line
#          HTML-comment markers; content outside the markers is
#          user-owned and never rewritten.
# -------------------------------------------------------------------

# shellcheck disable=SC2034  # read by commands/agents/sync.sh and lib/doctor.sh
AGENTS_LOCAL_FILE='AGENTS.local.md'
# shellcheck disable=SC2034  # read by commands/agents/sync.sh and lib/doctor.sh
AGENTS_BEGIN_MARKER='<!-- git-shadow:agents begin -->'
# shellcheck disable=SC2034  # read by commands/agents/sync.sh and lib/doctor.sh
AGENTS_END_MARKER='<!-- git-shadow:agents end -->'

AGENTS_HEADING='## Git Shadow workflow for AI agents'

# Render the managed block body: the AGENTS_HEADING section of the
# AGENTS_TEMPLATE-selected template under TOOLKIT_ROOT, preamble
# excluded. Fails (ui_error + return 1) on an invalid flavor, a missing
# template, a missing heading, or an empty body — a render failure must
# never classify a file as stale.
agents_template_body() {
  local flavor="${AGENTS_TEMPLATE:-full}"
  local template
  case "$flavor" in
    full)  template="$TOOLKIT_ROOT/AGENTS.template.md" ;;
    ultra) template="$TOOLKIT_ROOT/AGENTS.template.ultra.md" ;;
    *)
      ui_error "Invalid AGENTS_TEMPLATE '$flavor' (valid values: full, ultra)."
      return 1
      ;;
  esac

  if [[ ! -f "$template" ]]; then
    ui_error "Agents template not found: $template"
    return 1
  fi
  if ! grep -qxF "$AGENTS_HEADING" "$template"; then
    ui_error "Agents template lacks heading '$AGENTS_HEADING': $template"
    return 1
  fi

  local body
  body="$(sed -n "/^${AGENTS_HEADING}\$/,\$p" "$template")"
  if ! sed '1d' <<<"$body" | grep -q '[^[:space:]]'; then
    ui_error "Agents template body is empty after '$AGENTS_HEADING': $template"
    return 1
  fi

  # Trim trailing whitespace-only lines (the heading is line 1 already).
  body="${body%"${body##*[![:space:]]}"}"
  printf '%s\n' "$body"
}

# Render the desired block (begin marker + body + end marker, LF).
agents_block_fresh() {
  local body
  body="$(agents_template_body)" || return 1
  printf '%s\n%s\n%s' "$AGENTS_BEGIN_MARKER" "$body" "$AGENTS_END_MARKER"
}

# Print the line numbers of whole-line occurrences of marker $2 in file
# $1, one per line. A trailing CR is tolerated (CRLF materializations).
_agents_marker_lines() {
  local file="$1" marker="$2"
  local n=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    if [[ "$line" == "$marker" ]]; then
      printf '%s\n' "$n"
    fi
  done < "$file"
  return 0
}

# Print '<begin_line> <end_line>' when file $1 has exactly one begin and
# one end marker in begin<end order; return 1 otherwise (absent file,
# absent/unpaired/reversed/duplicated markers all reject).
agents_block_bounds() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local begins ends
  begins="$(_agents_marker_lines "$file" "$AGENTS_BEGIN_MARKER")"
  ends="$(_agents_marker_lines "$file" "$AGENTS_END_MARKER")"
  [[ "$begins" =~ ^[0-9]+$ && "$ends" =~ ^[0-9]+$ && $begins -lt $ends ]] || return 1
  printf '%s %s\n' "$begins" "$ends"
}

# Print the installed begin-through-end block from file $1 (raw bytes).
# Returns 1 on absent/unpaired/reversed/duplicated markers or a missing
# file — the same rejection set as agents_block_bounds.
agents_block_extract() {
  local file="$1"
  local bounds
  bounds="$(agents_block_bounds "$file")" || return 1
  sed -n "${bounds%% *},${bounds##* }p" "$file"
}

# Classify file $1: missing | absent | malformed | stale | current.
# Missing/absent/malformed classify without rendering; a render failure
# propagates as return 1 (no state printed) — callers report it rather
# than treating the file as stale.
agents_block_state() {
  local file="$1"
  if [[ -L "$file" ]]; then
    printf 'malformed\n'
    return 0
  fi
  if [[ ! -f "$file" ]]; then
    printf 'missing\n'
    return 0
  fi

  local begins ends
  begins="$(_agents_marker_lines "$file" "$AGENTS_BEGIN_MARKER")"
  ends="$(_agents_marker_lines "$file" "$AGENTS_END_MARKER")"
  if [[ -z "$begins" && -z "$ends" ]]; then
    printf 'absent\n'
    return 0
  fi
  if ! [[ "$begins" =~ ^[0-9]+$ && "$ends" =~ ^[0-9]+$ && $begins -lt $ends ]]; then
    printf 'malformed\n'
    return 0
  fi

  local installed desired
  installed="$(sed -n "${begins},${ends}p" "$file" | sed 's/\r$//')"
  desired="$(agents_block_fresh)" || return 1
  if [[ "$installed" == "$desired" ]]; then
    printf 'current\n'
  else
    printf 'stale\n'
  fi
}

# Reconcile file $1 with the fresh block: create it when missing, append
# when no markers exist, regenerate in place when stale, no-op when
# current. Refuses (ui_error + return 1) on malformed marker structure,
# symlinks, and non-regular existing files. The fresh block renders
# before any write and the file swaps via temp+rename, so a failure
# leaves the original byte-identical. Temp cleanup is explicit — no
# trap … RETURN (unsafe under bats functrace).
agents_block_install() {
  local file="$1"

  if [[ -L "$file" ]]; then
    ui_error "Refusing to write through symlink: $file"
    return 1
  fi
  if [[ -e "$file" && ! -f "$file" ]]; then
    ui_error "Not a regular file: $file"
    return 1
  fi

  local desired
  desired="$(agents_block_fresh)" || return 1

  local begins="" ends=""
  if [[ -f "$file" ]]; then
    begins="$(_agents_marker_lines "$file" "$AGENTS_BEGIN_MARKER")"
    ends="$(_agents_marker_lines "$file" "$AGENTS_END_MARKER")"
    if [[ -n "$begins" || -n "$ends" ]]; then
      if ! [[ "$begins" =~ ^[0-9]+$ && "$ends" =~ ^[0-9]+$ && $begins -lt $ends ]]; then
        ui_error "Malformed git-shadow agents markers in: $file"
        return 1
      fi
      local installed
      installed="$(sed -n "${begins},${ends}p" "$file" | sed 's/\r$//')"
      if [[ "$installed" == "$desired" ]]; then
        return 0
      fi
    fi
  fi

  local tmp
  tmp="$(mktemp "${file}.XXXXXX")" || return 1

  if [[ ! -e "$file" ]]; then
    printf '%s\n' "$desired" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    return 0
  fi

  if [[ -z "$begins" && -z "$ends" ]]; then
    {
      cat "$file"
      if [[ -s "$file" ]]; then
        # Terminate an unterminated final line, then one blank separator.
        if [[ -n "$(tail -c1 "$file")" ]]; then
          printf '\n'
        fi
        printf '\n'
      fi
      printf '%s\n' "$desired"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    return 0
  fi

  {
    head -n "$((begins - 1))" "$file"
    printf '%s\n' "$desired"
    tail -n "+$((ends + 1))" "$file"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}
