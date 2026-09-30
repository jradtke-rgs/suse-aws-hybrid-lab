#!/usr/bin/env python3
"""Emit the subset of a tfvars file that one component actually declares.

Why this exists
---------------
This repo keeps a single terraform.tfvars at the root holding settings for
every component. Handing that whole file to a component that declares only
six of its forty variables makes OpenTofu print a "Value for undeclared
variable" warning for each of the other thirty-four - on every plan, every
apply, for every component. The warnings are harmless and they bury real
ones.

So democtl generates a per-component democtl.auto.tfvars holding only the keys
that component declares (its own variables.tf plus the symlinked
common-vars.tf), copied verbatim from the root file. OpenTofu picks up
*.auto.tfvars automatically, so no -var-file flag is needed either.

This is a deliberately small HCL reader, not a general one. It handles what
a tfvars file actually contains: scalar assignments, multi-line lists and
maps, comments, and heredocs. It never evaluates anything - values are
copied across as raw text, so quoting and types are preserved exactly.
"""

import argparse
import re
import sys

ASSIGN_RE = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*=(.*)$')
VARIABLE_RE = re.compile(r'^\s*variable\s+"([^"]+)"\s*\{')
HEREDOC_RE = re.compile(r'<<[-~]?\s*([A-Za-z_][A-Za-z0-9_]*)')


def declared_variables(tf_files):
    """Variable names declared by a set of .tf files."""
    names = set()
    for path in tf_files:
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    match = VARIABLE_RE.match(line)
                    if match:
                        names.add(match.group(1))
        except OSError as exc:
            print(f"warning: {path}: {exc}", file=sys.stderr)
    return names


def _scan_depth(text, depth, in_string):
    """Track bracket depth across a line, ignoring anything inside strings.

    Returns (depth, in_string). Comments end the line unless we are inside a
    string or still nested inside brackets opened on an earlier line.
    """
    index = 0
    length = len(text)
    while index < length:
        char = text[index]
        if in_string:
            if char == "\\":
                index += 2
                continue
            if char == '"':
                in_string = False
        else:
            if char == '"':
                in_string = True
            elif char == "#":
                break
            elif char == "/" and index + 1 < length and text[index + 1] == "/":
                break
            elif char in "[{(":
                depth += 1
            elif char in "]})":
                depth -= 1
        index += 1
    return depth, in_string


def parse_tfvars(path):
    """Yield (name, raw_value_text) pairs, preserving the original text."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.readlines()

    entries = []
    index = 0
    total = len(lines)
    while index < total:
        match = ASSIGN_RE.match(lines[index])
        if not match:
            index += 1
            continue

        name = match.group(1)
        first = match.group(2)
        value_lines = [first.rstrip("\n")]

        heredoc = HEREDOC_RE.search(first)
        if heredoc:
            terminator = heredoc.group(1)
            index += 1
            while index < total:
                value_lines.append(lines[index].rstrip("\n"))
                if lines[index].strip() == terminator:
                    break
                index += 1
        else:
            depth, in_string = _scan_depth(first, 0, False)
            while depth > 0 and index + 1 < total:
                index += 1
                value_lines.append(lines[index].rstrip("\n"))
                depth, in_string = _scan_depth(lines[index], depth, in_string)

        # The trailing comment on a single-line value is kept, not stripped:
        # a ##UPDATE## marker IS a trailing comment in HCL, and a prior
        # version of this function stripped it as decoration - which
        # silently defeated the whole ##UPDATE## safety check downstream
        # (tofu_prepare's per-component scan never saw it, so `democtl
        # build` would have applied with secrets still blank). Confirmed
        # live while testing rancher-manager. `tfvars_generate` now runs
        # `tofu fmt` on its own output instead of hand-stripping comments
        # to satisfy `tofu fmt -check` - that was the only reason this
        # function existed.
        raw = "\n".join(value_lines).strip()
        entries.append((name, raw))
        index += 1

    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tfvars", required=True,
                        help="root terraform.tfvars to read")
    parser.add_argument("--tf-file", action="append", default=[],
                        help="a .tf file whose variable blocks define what is declared (repeatable)")
    parser.add_argument("--set", action="append", default=[], metavar="KEY=VALUE",
                        help="inject a string value democtl computes rather than reads (repeatable)")
    parser.add_argument("--out", required=True, help="file to write")
    parser.add_argument("--component", default="", help="component name, for the file header")
    args = parser.parse_args()

    declared = declared_variables(args.tf_file)
    if not declared:
        print("error: no variable blocks found - is this a tofu component?", file=sys.stderr)
        return 1

    entries = parse_tfvars(args.tfvars)
    seen = set()
    kept = []
    for name, value in entries:
        if name in declared:
            kept.append((name, value))
            seen.add(name)

    # Injected values win over anything in the tfvars file: they are computed
    # facts (which bucket state lives in), not user preferences.
    injected = []
    for item in args.set:
        key, _, value = item.partition("=")
        if key in declared:
            injected.append((key, '"%s"' % value.replace('\\', '\\\\').replace('"', '\\"')))

    injected_keys = {key for key, _ in injected}
    kept = [(name, value) for name, value in kept if name not in injected_keys]

    # Align each group to its own widest key. `tofu fmt` treats a blank line
    # or comment as a group boundary, so aligning everything to one width
    # would leave the generated file failing `tofu fmt -check`.
    def aligned(pairs):
        if not pairs:
            return []
        width = max(len(name) for name, _ in pairs)
        return ["%-*s = %s" % (width, name, value) for name, value in pairs]

    out = [
        "# Generated by democtl - do not edit, do not commit.",
        "# Source: %s" % args.tfvars,
        "# Component: %s" % (args.component or "unknown"),
        "#",
        "# Holds only the variables this component declares. Edit the root",
        "# terraform.tfvars instead; this file is rewritten on every run.",
        "",
    ]
    out.extend(aligned(kept))
    if injected:
        out.append("")
        out.append("# Injected by democtl (computed, not read from terraform.tfvars)")
        out.extend(aligned(injected))
    out.append("")

    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out))

    unused = sorted(name for name, _ in entries if name not in declared)
    if unused:
        print("declared-elsewhere: " + " ".join(unused), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
