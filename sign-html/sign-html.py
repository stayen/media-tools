#!/usr/bin/env python3

# (c) 2026 Konstantin Boyandin <developer@boyandin.com>

"""
sign-html.py — Sign and verify static HTML files using an SSH Ed25519 private key.

Signing workflow:
  The script reads an HTML file up to (and including) the closing </html> tag,
  appends a newline, computes an Ed25519 signature over that content, then
  writes a new file with the signature embedded in an HTML comment after </html>.

Verification workflow:
  The script reads a signed HTML file, extracts the HTML comment containing the
  signature, strips it, and verifies the signature against the provided public key.

Usage:
  Sign one file:
    python sign-html.py sign --key ~/.ssh/id_ed25519 --file page.html --output-dir signed/

  Sign multiple files (batch):
    python sign-html.py sign --key ~/.ssh/id_ed25519 --files-glob "dist/**/*.html" --output-dir signed/

  Verify a file:
    python sign-html.py verify --pubkey ~/.ssh/id_ed25519.pub --file signed/page.html

  Store passphrase in keyring (run once):
    python sign-html.py store-passphrase --key ~/.ssh/id_ed25519

Options:
  --passphrase ENV_VAR   Read passphrase from environment variable (batch-safe).
  --no-passphrase        Key has no passphrase (skip all prompts).
  --keyring              Use system keyring for passphrase (requires `keyring` package).
"""

import argparse
import base64
import getpass
import glob
import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Dependency guards
# ---------------------------------------------------------------------------
try:
    from cryptography.hazmat.primitives.serialization import (
        load_ssh_private_key,
        load_ssh_public_key,
    )
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
    from cryptography.exceptions import InvalidSignature
except ImportError:
    sys.exit(
        "ERROR: 'cryptography' package not found.\n"
        "Install with:  pip install cryptography"
    )

# Optional keyring support
_KEYRING_AVAILABLE = False
try:
    import keyring as _keyring
    _KEYRING_AVAILABLE = True
except ImportError:
    pass

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
COMMENT_START = "<!-- html-sig:"
COMMENT_END   = "-->"
HTML_CLOSE_TAG_RE = re.compile(r"(</html\s*>)", re.IGNORECASE)
KEYRING_SERVICE = "html_sign"


# ---------------------------------------------------------------------------
# Passphrase helpers
# ---------------------------------------------------------------------------

def _resolve_passphrase(args) -> bytes | None:
    """
    Return passphrase as bytes, or None if the key has no passphrase.
    Priority order:
      1. --no-passphrase flag
      2. --passphrase <ENV_VAR>   (environment variable name)
      3. --keyring                (system keyring, keyed by private-key path)
      4. Interactive prompt (default interactive / tty mode)
    """
    if getattr(args, "no_passphrase", False):
        return None

    # From environment variable
    env_var = getattr(args, "passphrase", None)
    if env_var:
        value = os.environ.get(env_var)
        if value is None:
            sys.exit(f"ERROR: Environment variable '{env_var}' is not set.")
        return value.encode()

    # From system keyring
    if getattr(args, "keyring", False):
        if not _KEYRING_AVAILABLE:
            sys.exit(
                "ERROR: 'keyring' package not installed.\n"
                "Install with:  pip install keyring"
            )
        key_path = str(Path(args.key).expanduser().resolve())
        stored = _keyring.get_password(KEYRING_SERVICE, key_path)
        if stored is None:
            sys.exit(
                f"ERROR: No passphrase stored in keyring for '{key_path}'.\n"
                f"Store it first with:  python sign-html.py store-passphrase --key {args.key}"
            )
        return stored.encode()

    # Interactive prompt (only valid when attached to a tty)
    if sys.stdin.isatty():
        pp = getpass.getpass(f"Passphrase for {args.key} (press Enter if none): ")
        return pp.encode() if pp else None

    # Non-interactive without explicit passphrase source → fail safe
    sys.exit(
        "ERROR: Running in non-interactive mode without a passphrase source.\n"
        "Use --no-passphrase, --passphrase ENV_VAR, or --keyring."
    )


# ---------------------------------------------------------------------------
# Key loading
# ---------------------------------------------------------------------------

def load_private_key(key_path: str, passphrase: bytes | None) -> Ed25519PrivateKey:
    path = Path(key_path).expanduser()
    if not path.exists():
        sys.exit(f"ERROR: Private key not found: {path}")
    raw = path.read_bytes()
    try:
        key = load_ssh_private_key(raw, password=passphrase)
    except (ValueError, TypeError) as exc:
        sys.exit(f"ERROR loading private key: {exc}")
    if not isinstance(key, Ed25519PrivateKey):
        sys.exit(
            f"ERROR: Key at '{path}' is not an Ed25519 key "
            f"(found {type(key).__name__}). Only Ed25519 is supported."
        )
    return key


def load_public_key(pub_path: str) -> Ed25519PublicKey:
    path = Path(pub_path).expanduser()
    if not path.exists():
        sys.exit(f"ERROR: Public key not found: {path}")
    raw = path.read_bytes()
    try:
        key = load_ssh_public_key(raw)
    except (ValueError, TypeError) as exc:
        sys.exit(f"ERROR loading public key: {exc}")
    if not isinstance(key, Ed25519PublicKey):
        sys.exit(
            f"ERROR: Key at '{path}' is not an Ed25519 public key "
            f"(found {type(key).__name__})."
        )
    return key


# ---------------------------------------------------------------------------
# HTML content helpers
# ---------------------------------------------------------------------------

def extract_signable_content(html_bytes: bytes) -> bytes | None:
    """
    Return the canonical byte string to be signed: everything up to and
    including the closing </html> tag, followed by a single newline (LF).
    Returns None if no </html> tag is found.
    """
    text = html_bytes.decode("utf-8", errors="surrogateescape")
    match = None
    for m in HTML_CLOSE_TAG_RE.finditer(text):
        match = m  # keep last occurrence
    if match is None:
        return None
    canonical = text[: match.end()] + "\n"
    return canonical.encode("utf-8", errors="surrogateescape")


def strip_existing_signature(html_bytes: bytes) -> bytes:
    """Remove any previously appended signature comment block."""
    text = html_bytes.decode("utf-8", errors="surrogateescape")
    # Remove everything after (and including) the last </html> + optional
    # trailing whitespace + our comment
    pattern = re.compile(
        r"(</html\s*>)\s*<!--\s*html-sig:.*?-->",
        re.IGNORECASE | re.DOTALL,
    )
    cleaned = pattern.sub(r"\1", text)
    return cleaned.encode("utf-8", errors="surrogateescape")


def extract_signature_from_comment(html_bytes: bytes) -> bytes | None:
    """
    Find and return the raw signature bytes embedded in the HTML comment.
    The comment format is:
      <!-- html-sig: <base64url-encoded-signature> -->
    """
    text = html_bytes.decode("utf-8", errors="surrogateescape")
    pattern = re.compile(
        r"<!--\s*html-sig:\s*([A-Za-z0-9+/=_-]+)\s*-->",
        re.IGNORECASE,
    )
    matches = list(pattern.finditer(text))
    if not matches:
        return None
    encoded = matches[-1].group(1).strip()
    try:
        # Accept both standard and URL-safe base64
        sig = base64.b64decode(encoded + "==", altchars=b"-_")
        return sig
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Core sign / verify
# ---------------------------------------------------------------------------

def sign_html_file(
    html_path: Path,
    private_key: Ed25519PrivateKey,
    output_path: Path,
) -> None:
    """Sign html_path and write signed output to output_path."""
    raw = html_path.read_bytes()
    # Strip any pre-existing signature so re-signing is idempotent
    raw = strip_existing_signature(raw)
    content = extract_signable_content(raw)
    if content is None:
        print(f"  SKIP  {html_path}  (no </html> tag found)")
        return

    sig_bytes = private_key.sign(content)
    sig_b64   = base64.b64encode(sig_bytes).decode("ascii")

    comment = f"\n{COMMENT_START} {sig_b64} {COMMENT_END}\n"

    # Append comment after </html>
    text = raw.decode("utf-8", errors="surrogateescape")
    match = None
    for m in HTML_CLOSE_TAG_RE.finditer(text):
        match = m
    signed_text = text[: match.end()] + comment + text[match.end() :]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(signed_text.encode("utf-8", errors="surrogateescape"))
    print(f"  SIGNED  {html_path}  →  {output_path}")


def verify_html_file(html_path: Path, public_key: Ed25519PublicKey) -> bool:
    """
    Verify the signature in html_path.
    Returns True on success, False on failure.
    """
    raw = html_path.read_bytes()
    sig_bytes = extract_signature_from_comment(raw)
    if sig_bytes is None:
        print(f"  FAIL    {html_path}  (no signature comment found)")
        return False

    # Reconstruct the canonical content that was signed
    stripped = strip_existing_signature(raw)
    content   = extract_signable_content(stripped)
    if content is None:
        print(f"  FAIL    {html_path}  (no </html> tag found after stripping comment)")
        return False

    try:
        public_key.verify(sig_bytes, content)
        print(f"  OK      {html_path}")
        return True
    except InvalidSignature:
        print(f"  FAIL    {html_path}  (signature invalid — file may have been tampered with)")
        return False


# ---------------------------------------------------------------------------
# CLI sub-commands
# ---------------------------------------------------------------------------

def cmd_sign(args):
    passphrase  = _resolve_passphrase(args)
    private_key = load_private_key(args.key, passphrase)

    # Collect input files
    files: list[Path] = []
    if getattr(args, "file", None):
        files = [Path(args.file)]
    elif getattr(args, "files_glob", None):
        matched = glob.glob(args.files_glob, recursive=True)
        if not matched:
            sys.exit(f"ERROR: No files matched glob pattern '{args.files_glob}'")
        files = [Path(p) for p in sorted(matched) if Path(p).is_file()]
    else:
        sys.exit("ERROR: Specify --file or --files-glob.")

    output_dir = Path(args.output_dir) if args.output_dir else None

    for src in files:
        if output_dir:
            dest = output_dir / src.name
        elif args.output_file:
            if len(files) > 1:
                sys.exit("ERROR: --output-file can only be used with a single --file.")
            dest = Path(args.output_file)
        else:
            # Default: write alongside original with '.signed.html' suffix
            dest = src.with_name(src.stem + ".signed.html")
        sign_html_file(src, private_key, dest)


def cmd_verify(args):
    public_key = load_public_key(args.pubkey)

    files: list[Path] = []
    if getattr(args, "file", None):
        files = [Path(args.file)]
    elif getattr(args, "files_glob", None):
        matched = glob.glob(args.files_glob, recursive=True)
        files = [Path(p) for p in sorted(matched) if Path(p).is_file()]
    else:
        sys.exit("ERROR: Specify --file or --files-glob.")

    results = [verify_html_file(f, public_key) for f in files]
    n_ok   = sum(results)
    n_fail = len(results) - n_ok
    print(f"\nResult: {n_ok} OK, {n_fail} FAILED out of {len(results)} file(s).")
    if n_fail:
        sys.exit(1)


def cmd_store_passphrase(args):
    if not _KEYRING_AVAILABLE:
        sys.exit(
            "ERROR: 'keyring' package not installed.\n"
            "Install with:  pip install keyring"
        )
    key_path = str(Path(args.key).expanduser().resolve())
    pp = getpass.getpass(f"Enter passphrase for {key_path}: ")
    _keyring.set_password(KEYRING_SERVICE, key_path, pp)
    print(f"Passphrase stored in system keyring for '{key_path}'.")
    print("Use --keyring when signing to retrieve it automatically.")


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="html_sign",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # --- sign ---
    sign_p = sub.add_parser("sign", help="Sign HTML file(s)")
    sign_p.add_argument("--key",         required=True, help="Path to SSH Ed25519 private key")
    sign_p.add_argument("--file",        help="Single HTML file to sign")
    sign_p.add_argument("--files-glob",  dest="files_glob",
                        help="Glob pattern for batch signing, e.g. 'dist/**/*.html'")
    sign_p.add_argument("--output-dir",  dest="output_dir",
                        help="Directory to write signed files into")
    sign_p.add_argument("--output-file", dest="output_file",
                        help="Output file path (single-file mode only)")

    _add_passphrase_args(sign_p)

    # --- verify ---
    verify_p = sub.add_parser("verify", help="Verify signed HTML file(s)")
    verify_p.add_argument("--pubkey",     required=True, help="Path to SSH Ed25519 public key (.pub)")
    verify_p.add_argument("--file",       help="Single HTML file to verify")
    verify_p.add_argument("--files-glob", dest="files_glob",
                          help="Glob pattern for batch verification")

    # --- store-passphrase ---
    store_p = sub.add_parser("store-passphrase",
                              help="Store private key passphrase in the system keyring")
    store_p.add_argument("--key", required=True, help="Path to SSH Ed25519 private key")

    return parser


def _add_passphrase_args(p: argparse.ArgumentParser):
    group = p.add_mutually_exclusive_group()
    group.add_argument(
        "--no-passphrase",
        dest="no_passphrase",
        action="store_true",
        help="Key has no passphrase; skip all prompts",
    )
    group.add_argument(
        "--passphrase",
        metavar="ENV_VAR",
        help="Name of environment variable that holds the passphrase (batch-safe)",
    )
    group.add_argument(
        "--keyring",
        action="store_true",
        help="Retrieve passphrase from the system keyring (use store-passphrase first)",
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = build_parser()
    args   = parser.parse_args()

    dispatch = {
        "sign":             cmd_sign,
        "verify":           cmd_verify,
        "store-passphrase": cmd_store_passphrase,
    }
    dispatch[args.command](args)


if __name__ == "__main__":
    main()
