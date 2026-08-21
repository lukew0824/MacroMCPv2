"""
Verifies Auth0-issued bearer tokens for the streamable-http transport.
Implements the SDK's TokenVerifier protocol (mcp.server.auth.provider) -
verify_token(token) -> AccessToken | None, None meaning "reject".

This is the resource-server half of the OAuth setup in docs/auth-setup.md.
Auth0 is the authorization server (issues tokens, handles DCR, handles the
Google login); this file's only job is confirming a token presented to us
was actually issued by that tenant, for this API, and hasn't expired -
never anything about who's allowed to do what, which stays in fn_* and the
per-user_id scoping everywhere else.
"""

from __future__ import annotations

import jwt
from jwt import PyJWKClient
from mcp.server.auth.provider import AccessToken, TokenVerifier


class Auth0TokenVerifier(TokenVerifier):
    def __init__(self, domain: str, audience: str) -> None:
        self._issuer = f"https://{domain}/"
        self._audience = audience
        # Caches Auth0's public keys and handles rotation - the network
        # fetch to Auth0's JWKS endpoint only happens on a cache miss or
        # when a token's kid isn't among the cached keys.
        self._jwks_client = PyJWKClient(f"https://{domain}/.well-known/jwks.json")

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            signing_key = self._jwks_client.get_signing_key_from_jwt(token)
        except jwt.PyJWKClientConnectionError:
            # Auth0's JWKS endpoint is unreachable - that's OUR problem, not
            # evidence the token is bad. Let it propagate as a real error
            # instead of silently rejecting every request while this lasts,
            # which would look identical to a mass access revocation.
            raise
        except (jwt.PyJWKClientError, jwt.InvalidTokenError):
            # PyJWKClientError: no signing key matches this token's kid (a
            # forged token, or one signed with a key since rotated out).
            # InvalidTokenError: get_signing_key_from_jwt peeks at the
            # token's header before any signature check, so a string that
            # isn't even a well-formed JWT (not three dot-separated base64
            # segments) fails here as a DecodeError, never reaching
            # jwt.decode() below at all. Both cases mean the same thing:
            # not a valid token for us.
            return None

        try:
            claims = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                audience=self._audience,
                issuer=self._issuer,
            )
        except jwt.InvalidTokenError:
            # Wrong signature, wrong audience, wrong issuer, expired,
            # malformed - all of these mean "not a valid token for us",
            # not a bug. Reject, don't raise.
            return None

        scope = claims.get("scope", "")
        return AccessToken(
            token=token,
            client_id=claims.get("azp", "unknown"),
            scopes=scope.split() if scope else [],
            expires_at=claims.get("exp"),
            subject=claims.get("sub"),
            claims=claims,
        )
