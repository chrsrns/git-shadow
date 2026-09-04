#!/usr/bin/env python3
"""
Annotation engine for git-shadow local comments.

Subcommands:
  extract  --source <path> --pattern-triple <re> --pattern-local <re>
           --extract-triple <0|1> --extract-local <0|1>
           --clean-out <path> --records-out <path> --meta-out <path>
           [--existing-annotations <path>] [--threshold <float>]

  key      --search <path>

  render   --source <path> --annotations <path> --output <path>

  reapply  --source <path> --annotations <path> --output <path>

  reanchor --source <path> --annotations <path> --output <path>
             --threshold <float>

  merge    --base <path> --feature <path> --output <path>
"""

import argparse
import hashlib
import re
import sys
from difflib import SequenceMatcher


def error(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def warn(msg):
    print(f"warning: {msg}", file=sys.stderr)


def normalize_line(line):
    """CRLF -> LF and strip trailing whitespace."""
    return line.replace("\r\n", "\n").rstrip()


def normalize_block(lines):
    """Normalize a block for key comparison and matching."""
    return [normalize_line(l) for l in lines]


def key_for_search(search_lines):
    """SHA-1 of normalized search block."""
    block = "\n".join(normalize_block(search_lines))
    return hashlib.sha1(block.encode("utf-8")).hexdigest()


def load_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def save_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def is_marker_line(line, patterns):
    for pat in patterns:
        if pat.match(line):
            return True
    return False


def parse_annotations(text, pattern_triple=None, pattern_local=None, for_marker_extraction=False):
    """Parse an annotation file into a list of records.

    Each record is a dict with: key, search_lines, replace_sections, marker_groups, split.
    If for_marker_extraction is True, the active regexes are used to identify
    marker groups inside replace sections.
    """
    records = []
    lines = text.splitlines()
    i = 0
    n = len(lines)
    active_pats = []
    if pattern_triple:
        active_pats.append(pattern_triple)
    if pattern_local:
        active_pats.append(pattern_local)

    while i < n:
        line = lines[i]
        if line.startswith("## hunk "):
            rest = line[len("## hunk "):].strip()
            # hidden metadata on same line may follow
            original_pos = None
            if "<!--" in rest:
                meta = rest[rest.find("<!--"):]
                m = re.search(r'op:\s*(\d+)', meta)
                if m:
                    original_pos = int(m.group(1))
                rest = rest[:rest.find("<!--")].strip()
            key = rest
            i += 1
            search_lines = []
            replace_sections = []
            section = None
            while i < n:
                current = lines[i]
                if current.startswith("## hunk "):
                    break
                if current == "### search":
                    section = "search"
                    i += 1
                    continue
                if current == "### replace":
                    section = "replace"
                    replace_sections.append([])
                    i += 1
                    continue
                if current == "### orphan":
                    section = "orphan"
                    i += 1
                    continue
                if section == "search":
                    search_lines.append(current)
                elif section == "replace":
                    replace_sections[-1].append(current)
                elif section == "orphan":
                    pass
                else:
                    pass
                i += 1
            marker_groups = []
            split = None
            if for_marker_extraction and active_pats:
                for rep in replace_sections:
                    mg = extract_marker_group(rep, active_pats)
                    marker_groups.append(mg)
                if replace_sections and marker_groups:
                    split = find_split_index(replace_sections[0], marker_groups[0], active_pats)
            records.append({
                "key": key,
                "search_lines": search_lines,
                "replace_sections": replace_sections,
                "marker_groups": marker_groups,
                "split": split,
                "original_pos": original_pos,
            })
        else:
            i += 1
    return records


def extract_marker_group(lines, patterns):
    """Find the contiguous marker block in a replace section."""
    best = []
    current = []
    for line in lines:
        if is_marker_line(line, patterns):
            current.append(line)
        else:
            if len(current) > len(best):
                best = current
            current = []
    if len(current) > len(best):
        best = current
    return best


def find_split_index(replace_lines, marker_group, patterns):
    """Return the index in the first replace section where the marker group starts."""
    if not marker_group:
        return None
    # marker group is a contiguous run of pattern-matching lines inside replace_lines
    for i in range(len(replace_lines) - len(marker_group) + 1):
        if replace_lines[i:i + len(marker_group)] == marker_group:
            return i
    return None


def find_subarray(haystack, needle, start=0):
    """Find the first contiguous occurrence of needle in haystack."""
    if not needle:
        return 0
    n = len(haystack)
    m = len(needle)
    for i in range(start, n - m + 1):
        if haystack[i:i + m] == needle:
            return i
    return -1


def count_subarray(haystack, needle):
    count = 0
    n = len(haystack)
    m = len(needle)
    for i in range(n - m + 1):
        if haystack[i:i + m] == needle:
            count += 1
    return count


def render_annotated(source_lines, records, patterns, for_reapply=False):
    """Return a list of output lines and a list of orphan warnings."""
    out_lines = []
    idx = 0
    orphans = []
    for rec in records:
        search = rec["search_lines"]
        pos = find_subarray(source_lines, search, idx)
        if pos == -1:
            orphans.append(rec["key"])
            continue
        out_lines.extend(source_lines[idx:pos])
        # Determine split from the first replace section, or default to center
        split = rec["split"]
        if split is None or split < 0 or split > len(search):
            split = len(search) // 2
        marker_groups = rec["marker_groups"] or [[]]
        # Insert all marker groups in chronological order
        all_markers = []
        for mg in marker_groups:
            all_markers.extend(mg)
        out_lines.extend(search[:split])
        out_lines.extend(all_markers)
        out_lines.extend(search[split:])
        idx = pos + len(search)
    out_lines.extend(source_lines[idx:])
    return out_lines, orphans


def jaccard(a, b):
    a = set(a)
    b = set(b)
    if not a and not b:
        return 1.0
    union = a | b
    if not union:
        return 0.0
    return len(a & b) / len(union)


def normalize_leading(lines):
    """Remove the smallest common leading whitespace from non-empty lines."""
    non_empty = [l for l in lines if l.strip()]
    if not non_empty:
        return lines
    min_ws = min(len(l) - len(l.lstrip(" ")) for l in non_empty)
    return [l[min_ws:] if l.strip() or min_ws <= len(l) else l for l in lines]


def find_fuzzy_match(search_lines, source_lines, threshold, original_pos=None):
    """Find the best candidate hunk in source_lines for search_lines.

    Uses normalized line sets and Jaccard similarity. Returns (pos, score) or (None, None).
    """
    if not search_lines:
        return None, None
    search_norm = set(normalize_leading(normalize_block(search_lines)))
    best_pos = None
    best_score = 0.0
    best_dist = float("inf")
    m = len(search_lines)
    n = len(source_lines)
    for i in range(n - m + 1):
        window = source_lines[i:i + m]
        window_norm = set(normalize_leading(normalize_block(window)))
        score = jaccard(search_norm, window_norm)
        if score > best_score or (score == best_score and score >= threshold):
            dist = abs(i - original_pos) if original_pos is not None else i
            if score > best_score or (score == best_score and dist < best_dist):
                best_score = score
                best_pos = i
                best_dist = dist
    if best_score >= threshold:
        return best_pos, best_score
    return None, best_score


def align_split(old_search, new_search, old_split):
    """Map an old split index to the new search block using LCS."""
    sm = SequenceMatcher(None, old_search, new_search)
    # Build a map old_index -> new_index for matched lines
    matches = {}
    for block in sm.get_matching_blocks():
        for k in range(block.size):
            old_i = block.a + k
            new_i = block.b + k
            matches[old_i] = new_i
    # We need the new index corresponding to the position after old_split lines.
    # If old_split lines are matched, find the largest new index among them.
    # Then add 1 to get the insertion point between before and after.
    best = -1
    for old_i in range(old_split):
        if old_i in matches:
            best = max(best, matches[old_i])
    if best == -1:
        return 0
    # The insertion point is after the matched before block. If some before lines
    # were deleted, best is the index of the last matched before line.
    return best + 1


def reanchor_records(records, source_lines, patterns, threshold):
    """Re-anchor records against a new source. Returns new records and orphan keys."""
    orphans = []
    new_records = []
    for rec in records:
        search = rec["search_lines"]
        pos = find_subarray(source_lines, search)
        if pos != -1:
            # exact match - key unchanged, but if the hunk has new neighbours the
            # search block might still be identical while source around it changed.
            # The record stays valid.
            new_records.append(rec)
            continue
        original_pos = rec.get("original_pos")
        if original_pos is None:
            original_pos = 0
        fuzzy_pos, _ = find_fuzzy_match(search, source_lines, threshold, original_pos=original_pos)
        if fuzzy_pos is None:
            orphans.append(rec["key"])
            new_records.append(rec)
            continue
        candidate = source_lines[fuzzy_pos:fuzzy_pos + len(search)]
        old_split = rec["split"]
        if old_split is None:
            old_split = len(search) // 2
        new_split = align_split(search, candidate, old_split)
        marker_groups = rec["marker_groups"] or [[]]
        all_markers = []
        for mg in marker_groups:
            all_markers.extend(mg)
        new_replace = candidate[:new_split] + all_markers + candidate[new_split:]
        new_key = key_for_search(candidate)
        new_records.append({
            "key": new_key,
            "search_lines": candidate,
            "replace_sections": [new_replace],
            "marker_groups": marker_groups,
            "split": new_split,
        })
    return new_records, orphans


def records_to_text(records, keep_all_replaces=True):
    """Serialize records to annotation file text."""
    parts = []
    for rec in records:
        op = rec.get("original_pos")
        op_tag = f"<!-- op:{op} -->" if op is not None else ""
        parts.append(f"## hunk {rec['key']} {op_tag}".rstrip())
        parts.append("### search")
        for line in rec["search_lines"]:
            parts.append(line)
        replaces = rec["replace_sections"]
        if not keep_all_replaces and replaces:
            replaces = [replaces[-1]]
        for rep in replaces:
            parts.append("### replace")
            for line in rep:
                parts.append(line)
    return "\n".join(parts) + "\n" if parts else ""


def merge_records(base_records, feature_records, mode="append"):
    """Merge feature records into base.

    mode='append' (feature finish): same hunk key appends replace sections.
    mode='replace' (git shadow commit): same hunk key is replaced with the
    latest extracted block.
    """
    base_by_key = {r["key"]: r for r in base_records}
    for frec in feature_records:
        key = frec["key"]
        if key in base_by_key:
            if mode == "append":
                base_by_key[key]["replace_sections"].extend(frec["replace_sections"])
                base_by_key[key]["marker_groups"].extend(frec["marker_groups"])
            else:
                base_by_key[key]["search_lines"] = frec["search_lines"]
                base_by_key[key]["replace_sections"] = frec["replace_sections"]
                base_by_key[key]["marker_groups"] = frec["marker_groups"]
                base_by_key[key]["split"] = frec["split"]
                base_by_key[key]["original_pos"] = frec["original_pos"]
        else:
            base_records.append(frec)
    return base_records


def extract(source_text, pattern_triple, pattern_local, extract_triple, extract_local, existing_records=None):
    """Extract local markers from source text and return (clean_content, records, has_markers, marker_only, error)."""
    patterns = []
    if extract_triple and pattern_triple:
        patterns.append(pattern_triple)
    if extract_local and pattern_local:
        patterns.append(pattern_local)

    if not patterns:
        # nothing to extract, source is clean
        return source_text, [], False, False, None

    lines = source_text.splitlines()
    is_marker = [is_marker_line(line, patterns) for line in lines]

    if not any(is_marker):
        return source_text, [], False, False, None

    # marker-only if all lines are markers
    if all(is_marker):
        return "", [], True, True, None

    clean_lines = [line for line, marker in zip(lines, is_marker) if not marker]

    # find marker blocks
    blocks = []
    i = 0
    while i < len(lines):
        if is_marker[i]:
            start = i
            while i < len(lines) and is_marker[i]:
                i += 1
            end = i
            blocks.append((start, end))
        else:
            i += 1

    records = []
    for start, end in blocks:
        before = []
        after = []
        b_pos = start - 1
        a_pos = end

        def can_before(pos):
            return pos >= 0 and not is_marker[pos]

        def can_after(pos):
            return pos < len(lines) and not is_marker[pos]

        # initial one before, one after
        if can_before(b_pos):
            before.insert(0, lines[b_pos])
            b_pos -= 1
        if can_after(a_pos):
            after.append(lines[a_pos])
            a_pos += 1

        # If we ended up with no context at all, this block has no public anchor.
        # That can only happen if the file is marker-only, which we already handled.
        if not before and not after:
            return source_text, [], True, True, None

        # expand until the search block is unique in the clean source
        while True:
            search_lines = before + after
            if count_subarray(clean_lines, search_lines) == 1:
                break
            expanded = False
            if can_before(b_pos):
                before.insert(0, lines[b_pos])
                b_pos -= 1
                expanded = True
                if count_subarray(clean_lines, before + after) == 1:
                    break
            if can_after(a_pos):
                after.append(lines[a_pos])
                a_pos += 1
                expanded = True
                if count_subarray(clean_lines, before + after) == 1:
                    break
            if not expanded:
                return None, [], True, False, f"cannot find unique search block for marker at line {start + 1}"

        marker_lines = lines[start:end]
        replace_lines = before + marker_lines + after
        search_lines = before + after
        # split is the boundary between before and after in the search block
        split = len(before)
        original_pos = find_subarray(clean_lines, search_lines)
        records.append({
            "key": key_for_search(search_lines),
            "search_lines": search_lines,
            "replace_sections": [replace_lines],
            "marker_groups": [marker_lines],
            "split": split,
            "original_pos": original_pos,
        })

    # Merge with existing records. For git shadow commit semantics, a newly
    # extracted hunk with the same key replaces the old replace section(s).
    if existing_records:
        records = merge_records(existing_records, records, mode="replace")

    # clean content: remove active marker lines
    clean_text = "\n".join(clean_lines)
    if source_text.endswith("\n"):
        clean_text += "\n"
    return clean_text, records, True, False, None


def dedup_records_to_latest(records):
    """For records with the same key, keep only the latest (last) replace section."""
    seen = {}
    result = []
    for rec in records:
        key = rec["key"]
        if key in seen:
            seen[key] = rec
        else:
            seen[key] = rec
    # preserve order of first appearance
    for rec in records:
        key = rec["key"]
        if seen[key] is not None:
            result.append(seen[key])
            seen[key] = None
    return result


def main_extract(args):
    patterns = []
    if args.pattern_triple:
        patterns.append(re.compile(args.pattern_triple))
    if args.pattern_local:
        patterns.append(re.compile(args.pattern_local))

    existing_records = None
    if args.existing_annotations:
        existing_text = load_text(args.existing_annotations)
        existing_records = parse_annotations(existing_text, patterns[0] if patterns else None, patterns[1] if len(patterns) > 1 else None, for_marker_extraction=True)

    source_text = load_text(args.source)
    pattern_triple = re.compile(args.pattern_triple) if args.pattern_triple else None
    pattern_local = re.compile(args.pattern_local) if args.pattern_local else None

    clean_content, records, has_markers, marker_only, err = extract(
        source_text, pattern_triple, pattern_local,
        args.extract_triple == "1", args.extract_local == "1",
        existing_records=existing_records,
    )

    if err:
        save_text(args.meta_out, f"has_markers=true\nrecord_count=0\nmarker_only=false\nerror={err}")
        sys.exit(1)

    if clean_content is not None:
        save_text(args.clean_out, clean_content)
    else:
        save_text(args.clean_out, "")

    if records:
        save_text(args.records_out, records_to_text(records, keep_all_replaces=True))
    else:
        save_text(args.records_out, "")

    save_text(args.meta_out, f"has_markers={'true' if has_markers else 'false'}\nrecord_count={len(records)}\nmarker_only={'true' if marker_only else 'false'}\n")


def main_key(args):
    search_text = load_text(args.search)
    search_lines = search_text.splitlines()
    print(key_for_search(search_lines))


def main_render_or_reapply(args, is_reapply):
    source_text = load_text(args.source)
    pattern_triple = re.compile(args.pattern_triple) if args.pattern_triple else None
    pattern_local = re.compile(args.pattern_local) if args.pattern_local else None
    patterns = [p for p in [pattern_triple, pattern_local] if p]
    source_lines = [line for line in source_text.splitlines() if not is_marker_line(line, patterns)]
    ann_text = load_text(args.annotations)
    records = parse_annotations(ann_text, pattern_triple, pattern_local, for_marker_extraction=True)
    out_lines, orphans = render_annotated(source_lines, records, patterns, for_reapply=is_reapply)
    out_text = "\n".join(out_lines)
    if source_text.endswith("\n"):
        out_text += "\n"
    save_text(args.output, out_text)
    for key in orphans:
        warn(f"orphan hunk {key}: search block not found")


def main_render(args):
    main_render_or_reapply(args, is_reapply=False)


def main_reapply(args):
    main_render_or_reapply(args, is_reapply=True)


def main_reanchor(args):
    source_text = load_text(args.source)
    pattern_triple = re.compile(args.pattern_triple) if args.pattern_triple else None
    pattern_local = re.compile(args.pattern_local) if args.pattern_local else None
    patterns = [p for p in [pattern_triple, pattern_local] if p]
    source_lines = [line for line in source_text.splitlines() if not is_marker_line(line, patterns)]
    ann_text = load_text(args.annotations)
    records = parse_annotations(ann_text, pattern_triple, pattern_local, for_marker_extraction=True)
    new_records, orphans = reanchor_records(records, source_lines, patterns, float(args.threshold))
    save_text(args.output, records_to_text(new_records, keep_all_replaces=True))
    for key in orphans:
        warn(f"orphan hunk {key}: could not re-anchor")


def main_merge(args):
    base_text = load_text(args.base)
    feature_text = load_text(args.feature)
    base_records = parse_annotations(base_text, for_marker_extraction=False)
    feature_records = parse_annotations(feature_text, for_marker_extraction=False)
    merged = merge_records(base_records, feature_records)
    save_text(args.output, records_to_text(merged, keep_all_replaces=True))


def main():
    parser = argparse.ArgumentParser(prog="annotations.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    p_extract = subparsers.add_parser("extract")
    p_extract.add_argument("--source", required=True)
    p_extract.add_argument("--pattern-triple", default="^\\s*///")
    p_extract.add_argument("--pattern-local", default="^\\s*// @local")
    p_extract.add_argument("--extract-triple", default="1")
    p_extract.add_argument("--extract-local", default="1")
    p_extract.add_argument("--existing-annotations", default=None)
    p_extract.add_argument("--threshold", default="0.80")
    p_extract.add_argument("--clean-out", required=True)
    p_extract.add_argument("--records-out", required=True)
    p_extract.add_argument("--meta-out", required=True)
    p_extract.set_defaults(func=main_extract)

    p_key = subparsers.add_parser("key")
    p_key.add_argument("--search", required=True)
    p_key.set_defaults(func=main_key)

    p_render = subparsers.add_parser("render")
    p_render.add_argument("--source", required=True)
    p_render.add_argument("--annotations", required=True)
    p_render.add_argument("--output", required=True)
    p_render.add_argument("--pattern-triple", default="^\\s*///")
    p_render.add_argument("--pattern-local", default="^\\s*// @local")
    p_render.set_defaults(func=main_render)

    p_reapply = subparsers.add_parser("reapply")
    p_reapply.add_argument("--source", required=True)
    p_reapply.add_argument("--annotations", required=True)
    p_reapply.add_argument("--output", required=True)
    p_reapply.add_argument("--pattern-triple", default="^\\s*///")
    p_reapply.add_argument("--pattern-local", default="^\\s*// @local")
    p_reapply.set_defaults(func=main_reapply)

    p_reanchor = subparsers.add_parser("reanchor")
    p_reanchor.add_argument("--source", required=True)
    p_reanchor.add_argument("--annotations", required=True)
    p_reanchor.add_argument("--output", required=True)
    p_reanchor.add_argument("--threshold", default="0.80")
    p_reanchor.add_argument("--pattern-triple", default="^\\s*///")
    p_reanchor.add_argument("--pattern-local", default="^\\s*// @local")
    p_reanchor.set_defaults(func=main_reanchor)

    p_merge = subparsers.add_parser("merge")
    p_merge.add_argument("--base", required=True)
    p_merge.add_argument("--feature", required=True)
    p_merge.add_argument("--output", required=True)
    p_merge.set_defaults(func=main_merge)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
