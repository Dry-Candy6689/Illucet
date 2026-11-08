"""Request-local account cookie jars; never persist cookies or reuse a session."""
from contextlib import contextmanager


@contextmanager
def downloader(request, factory, options):
    # Lazy imports avoid changing the ordinary extractor initialization order.
    from illucet_session_probe import _cookies
    from illucet_ytdlp_extractor import SafeExtractionFailure
    authenticated = "account_cookies" in request
    cookies = _cookies(request["account_cookies"]) if authenticated else []
    if authenticated:
        options = dict(options, age_limit=None)
    with factory(options) as ydl:
        try:
            if authenticated:
                for cookie in cookies:
                    ydl.cookiejar.set_cookie(cookie)
                youtube = ydl.get_info_extractor("Youtube")
                if not youtube.is_authenticated:
                    raise SafeExtractionFailure("session_expired", "Sign in to this account again.")
                verify_server_session(youtube)
            yield ydl
            if authenticated and not ydl.get_info_extractor("Youtube").is_authenticated:
                raise SafeExtractionFailure("session_expired", "This account session expired. Sign in again.")
        finally:
            if authenticated:
                ydl.cookiejar.clear()
                cookies.clear()


def verify_server_session(youtube):
    """Cookie names alone do not prove the service accepts an account session."""
    from illucet_ytdlp_extractor import SafeExtractionFailure
    webpage = youtube._download_webpage(
        "https://www.youtube.com/", None, note="Checking account session")
    config = youtube.extract_ytcfg(None, webpage)
    logged_in = config.get("LOGGED_IN") if isinstance(config, dict) else None
    if logged_in is False:
        raise SafeExtractionFailure("session_expired", "This account session expired. Sign in again.")
    if logged_in is not True:
        raise SafeExtractionFailure("session_unverified", "YouTube did not confirm this account session. Try signing in again.")


def validate_media_transport(raw_format):
    """Account extraction never implies permission to forward media credentials."""
    from illucet_ytdlp_extractor import SafeExtractionFailure
    headers = raw_format.get("http_headers")
    if raw_format.get("cookies") not in (None, "") or (
        isinstance(headers, dict) and any(str(key).lower() in
            {"cookie", "cookie2", "authorization", "proxy-authorization"} for key in headers)
    ):
        raise SafeExtractionFailure("authenticated_transport_unsupported",
            "This format needs credentials during media transfer, which Illucet does not support.")
