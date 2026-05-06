# sign-html.py

sign-html.py — Sign and verify static HTML files using an SSH Ed25519 private key.

## Signing workflow:

The script reads an HTML file up to (and including) the closing </html> tag,
appends a newline, computes an Ed25519 signature over that content, then
writes a new file with the signature embedded in an HTML comment after </html>.

## Verification workflow:

The script reads a signed HTML file, extracts the HTML comment containing the
signature, strips it, and verifies the signature against the provided public key.

## Usage

  Sign one file:
```bash
    python sign-html.py sign --key ~/.ssh/id_ed25519 --file page.html --output-dir signed/
```

  Sign multiple files (batch):
```bash
    python sign-html.py sign --key ~/.ssh/id_ed25519 --files-glob "dist/**/*.html" --output-dir signed/
```

  Verify a file:
```bash
    python sign-html.py verify --pubkey ~/.ssh/id_ed25519.pub --file signed/page.html
```

  Store passphrase in keyring (run once):
```bash
    python sign-html.py store-passphrase --key ~/.ssh/id_ed25519
```

## Options
```text
  --passphrase ENV_VAR   Read passphrase from environment variable (batch-safe).
  --no-passphrase        Key has no passphrase (skip all prompts).
  --keyring              Use system keyring for passphrase (requires `keyring` package).
```