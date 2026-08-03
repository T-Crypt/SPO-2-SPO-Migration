#!/usr/bin/env python3
"""
PowerShell-aware structural validator.

This is NOT a full parser (no pwsh available in this sandbox). It tokenises
enough of the language to catch the gross structural errors that a parse-check
would flag: unbalanced (){}[], unterminated strings/here-strings, and a few
PS-specific gotchas the author called out.

It understands:
  * line comments  # ...
  * block comments <# ... #>
  * single-quoted strings '...'  ('' escape)
  * double-quoted strings "..."  (`" escape, $(...) subexpressions)
  * here-strings @" ... "@  and  @' ... '@
"""
import sys, os, re

class Issue:
    def __init__(self, path, line, msg):
        self.path, self.line, self.msg = path, line, msg
    def __str__(self):
        return f"{os.path.basename(self.path)}:{self.line}: {self.msg}"

def validate(path):
    issues = []
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()

    n = len(text)
    i = 0
    line = 1
    stack = []  # (char, line)
    pairs = {')': '(', ']': '[', '}': '{'}
    openers = set('([{')
    closers = set(')]}')

    def adv(count=1):
        nonlocal i, line
        for _ in range(count):
            if i < n and text[i] == '\n':
                line += 1
            i += 1

    while i < n:
        c = text[i]

        # newline / whitespace
        if c == '\n':
            adv(); continue

        # here-strings: @"  or  @'  must be followed by end-of-line
        if c == '@' and i + 1 < n and text[i+1] in '"\'':
            q = text[i+1]
            # confirm rest of line is whitespace
            j = i + 2
            rest_ok = True
            while j < n and text[j] != '\n':
                if not text[j].isspace():
                    rest_ok = False
                    break
                j += 1
            if rest_ok:
                start_line = line
                # terminator is a line that begins with "@ or '@ (optionally
                # preceded by whitespace? No: PS requires it at column 0-ish;
                # the closing "@ must be at the start of a line)
                term = q + '@'
                # advance to next line
                adv(2)  # consume @ and quote
                while i < n and text[i] != '\n':
                    adv()
                # now scan lines for terminator at line start
                closed = False
                while i < n:
                    adv()  # consume the newline -> now at line start
                    # check if line starts with term
                    if text[i:i+2] == term:
                        adv(2)
                        closed = True
                        break
                    # skip to end of this line
                    while i < n and text[i] != '\n':
                        adv()
                if not closed:
                    issues.append(Issue(path, start_line, f"unterminated here-string {q}@"))
                continue
            # else fall through, treat @ as normal char

        # block comment <# ... #>
        if c == '<' and i + 1 < n and text[i+1] == '#':
            start_line = line
            adv(2)
            closed = False
            while i < n:
                if text[i] == '#' and i + 1 < n and text[i+1] == '>':
                    adv(2); closed = True; break
                adv()
            if not closed:
                issues.append(Issue(path, start_line, "unterminated block comment <# #>"))
            continue

        # line comment
        if c == '#':
            while i < n and text[i] != '\n':
                adv()
            continue

        # backtick escape (line continuation or escaped char) outside strings
        if c == '`':
            adv(2)
            continue

        # single-quoted string
        if c == "'":
            start_line = line
            adv()
            closed = False
            while i < n:
                if text[i] == "'":
                    if i + 1 < n and text[i+1] == "'":
                        adv(2); continue  # '' escape
                    adv(); closed = True; break
                adv()
            if not closed:
                issues.append(Issue(path, start_line, "unterminated single-quoted string"))
            continue

        # double-quoted string
        if c == '"':
            start_line = line
            adv()
            closed = False
            while i < n:
                ch = text[i]
                if ch == '`':
                    adv(2); continue
                if ch == '"':
                    if i + 1 < n and text[i+1] == '"':
                        adv(2); continue
                    adv(); closed = True; break
                if ch == '$' and i + 1 < n and text[i+1] == '(':
                    # subexpression: track nested parens so we don't miscount
                    adv(2)
                    depth = 1
                    while i < n and depth > 0:
                        if text[i] == '`':
                            adv(2); continue
                        if text[i] == '(':
                            depth += 1
                        elif text[i] == ')':
                            depth -= 1
                        adv()
                    continue
                adv()
            if not closed:
                issues.append(Issue(path, start_line, "unterminated double-quoted string"))
            continue

        # brackets
        if c in openers:
            stack.append((c, line))
            adv(); continue
        if c in closers:
            if not stack:
                issues.append(Issue(path, line, f"unmatched closing '{c}'"))
            else:
                op, ol = stack.pop()
                if op != pairs[c]:
                    issues.append(Issue(path, line, f"mismatched '{c}' (opener '{op}' from line {ol})"))
            adv(); continue

        adv()

    for op, ol in stack:
        issues.append(Issue(path, ol, f"unclosed '{op}'"))

    return issues

def main():
    roots = sys.argv[1:] or ['.']
    files = []
    for r in roots:
        if os.path.isfile(r):
            files.append(r)
        else:
            for dp, _, fn in os.walk(r):
                for f in fn:
                    if f.endswith(('.ps1', '.psm1', '.psd1')):
                        files.append(os.path.join(dp, f))
    files.sort()
    total = 0
    for f in files:
        iss = validate(f)
        if iss:
            for x in iss:
                print("STRUCT", x)
            total += len(iss)
        else:
            print(f"ok     {os.path.relpath(f)}")
    print(f"\n{len(files)} files scanned, {total} structural issue(s).")
    sys.exit(1 if total else 0)

if __name__ == '__main__':
    main()
