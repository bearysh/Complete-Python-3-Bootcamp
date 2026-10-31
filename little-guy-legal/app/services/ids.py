import secrets


def new_id(prefix: str) -> str:
    """Unpredictable identifiers (128 bits of randomness)."""
    return f"{prefix}_{secrets.token_hex(16)}"
