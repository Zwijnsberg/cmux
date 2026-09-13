"""Point Python's TLS at certifi's CA bundle when the interpreter has none.

python.org macOS builds ship without root certificates, so aiohttp, websockets,
and nltk all fail with CERTIFICATE_VERIFY_FAILED. Setting SSL_CERT_FILE and
REQUESTS_CA_BUNDLE (only if unset) fixes every client.

This must run BEFORE aiohttp is imported: aiohttp builds and caches its default
SSL context when the module loads, reading SSL_CERT_FILE at that moment, so a
value set later (for example from ``main()`` after ``import bot``) is never
seen and every Ultravox call fails with "Failed to connect to Ultravox".
``server.py`` and ``bot.py`` therefore call this before any pipecat import.
This module deliberately imports nothing but the standard library and certifi.
"""

from __future__ import annotations

import os
import sys

TLS_ENV_VARS = ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE")


def configure_tls_certificates() -> None:
    try:
        import certifi
    except ImportError:
        return
    bundle = certifi.where()
    for var in TLS_ENV_VARS:
        os.environ.setdefault(var, bundle)


def aiohttp_imported_before_tls_setup() -> bool:
    """True when aiohttp is already loaded, which means its default SSL context
    may not trust the bundle we are about to point at. Used by the startup
    guard and its test."""
    return "aiohttp" in sys.modules
