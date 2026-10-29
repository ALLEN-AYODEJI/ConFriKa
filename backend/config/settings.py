import secrets
import logging
from typing import List, Optional
from pydantic_settings import BaseSettings, SettingsConfigDict

logger = logging.getLogger("confrika.settings")


class Settings(BaseSettings):
    APP_NAME: str = "ConFriKa Backend Services"
    APP_VERSION: str = "2.0.0"
    APP_ENV: str = "development"  # 'development' | 'production'
    DEBUG: bool = False

    # Comma-separated emails granted admin (dashboard) access on startup.
    ADMIN_EMAILS: str = ""

    # Security / JWT. SECRET_KEY must be supplied via environment in production.
    SECRET_KEY: Optional[str] = None
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60 * 24 * 7  # 7 days
    BCRYPT_ROUNDS: int = 12

    # Database & Redis
    DATABASE_URL: str = "sqlite+aiosqlite:///./confrika.db"
    REDIS_URL: str = "redis://localhost:6379/0"

    # CORS — comma separated list of allowed origins. Never wildcard in prod.
    ALLOWED_ORIGINS: str = "http://localhost:3000,http://localhost:8080"

    # Request limits
    MAX_TEXT_LENGTH: int = 5000
    MAX_AUDIO_BYTES: int = 20 * 1024 * 1024  # 20 MB

    # Media uploads (profile pictures, image messages). Stored on disk and
    # served from /media. Encrypted DM images are uploaded as ciphertext blobs.
    MEDIA_DIR: str = "/opt/confrika/media"
    MEDIA_MAX_BYTES: int = 8 * 1024 * 1024  # 8 MB per image

    # Email delivery (transactional OTP + password reset). Provider HTTP API.
    EMAIL_PROVIDER: str = "resend"  # 'resend' | 'sendgrid' | 'mailgun'
    EMAIL_API_KEY: str = ""          # provider secret; empty = dev mode (code logged)
    EMAIL_FROM: str = "ConFriKa <no-reply@confrika.com>"
    MAILGUN_DOMAIN: str = ""         # required only for the mailgun provider
    OTP_LENGTH: int = 6
    OTP_TTL_MINUTES: int = 10
    OTP_MAX_ATTEMPTS: int = 5

    @property
    def email_configured(self) -> bool:
        return bool(self.EMAIL_API_KEY and self.EMAIL_API_KEY.strip())

    # Translation engine
    TRANSLATION_PROVIDER: str = "nllb"  # 'nllb' | 'google' | 'mymemory' | 'echo'
    MYMEMORY_EMAIL: str = ""  # optional: raises MyMemory's free daily quota (~5k -> ~50k chars)
    NLLB_MODEL: str = "facebook/nllb-200-distilled-600M"
    NLLB_DEVICE: str = "cpu"  # 'cpu' | 'cuda'
    NLLB_MAX_INPUT_TOKENS: int = 512
    MODEL_CACHE_DIR: str = "/opt/confrika/models"
    TRANSLATION_WARMUP: bool = True
    # Optional managed fallback provider for languages NLLB-200 does not cover
    # (e.g. Tiv). Leave blank to run fully local on NLLB only. When set, the
    # translation router uses Google only for those gap languages; everything
    # NLLB supports stays local and free.
    GOOGLE_TRANSLATE_API_KEY: str = ""

    # Voice / Tonal pitch engine
    PITCH_ANALYSIS_MIN_F0: float = 70.0
    PITCH_ANALYSIS_MAX_F0: float = 350.0

    # Live in-call speech-to-speech translation (voice-preserving).
    # Empty VOICE_API_KEY => the pipeline runs in stub mode (no live audio).
    VOICE_PROVIDER: str = "elevenlabs"  # 'elevenlabs' | '' (stub)
    VOICE_API_KEY: str = ""
    VOICE_TTS_MODEL: str = "eleven_turbo_v2_5"   # low-latency streaming TTS
    VOICE_STT_MODEL: str = "scribe_v1"           # speech-to-text
    VOICE_MAX_CLIP_BYTES: int = 4 * 1024 * 1024  # 4 MB per translated utterance

    @property
    def voice_configured(self) -> bool:
        return bool(self.VOICE_API_KEY and self.VOICE_API_KEY.strip())

    # Push notifications (Firebase Cloud Messaging) — for message & call alerts.
    # Empty => stub mode (no pushes sent; tokens still registered).
    FCM_PROJECT_ID: str = ""
    FCM_CREDENTIALS_FILE: str = ""  # path to a Firebase service-account JSON

    @property
    def fcm_configured(self) -> bool:
        return bool(self.FCM_PROJECT_ID and self.FCM_CREDENTIALS_FILE)

    # ------------------------------------------------------------------ #
    # Monetization: ads + freemium subscription (ConFriKa Pro)
    # ------------------------------------------------------------------ #
    # Free-tier daily/standing limits. Pro lifts all of these.
    FREE_DAILY_TRANSLATIONS: int = 30
    FREE_DAILY_CALL_SECONDS: int = 900        # 15 minutes of translated calls
    FREE_MAX_COMMUNITIES: int = 2             # communities a free user may join
    FREE_CAN_CREATE_COMMUNITIES: bool = False
    FREE_VOICE_CLONE: bool = False            # voice-preserving calls are Pro-only
    ADS_ENABLED: bool = True                  # show ads to free users (client reads this)

    # Google Play subscription verification (Android). When a service-account
    # JSON + package name are set, purchases are verified against the Play
    # Developer API; otherwise /billing/verify rejects unverified tokens.
    PLAY_PACKAGE_NAME: str = "com.confrika.confrika_mobile"
    PLAY_SERVICE_ACCOUNT_FILE: str = ""       # path to a Play service-account JSON
    PRO_PRODUCT_IDS: str = "confrika_pro_monthly,confrika_pro_yearly"
    # Prices used to record revenue on each verified Pro purchase (set these to
    # your real store prices). A product id containing "year" uses the yearly price.
    PRO_MONTHLY_PRICE_CENTS: int = 299
    PRO_YEARLY_PRICE_CENTS: int = 2999
    REVENUE_CURRENCY: str = "USD"
    # Dev/testing escape hatch: trust the client's purchase claim without
    # server-side verification. MUST stay False in production.
    BILLING_TRUST_UNVERIFIED: bool = False

    # ── Teach-and-earn: learn from native speakers, teachers earn rewards ──
    # Rewards are a liability funded from app revenue (ads/Pro). Payouts are
    # tracked now; actual disbursement ("withdraw") is Coming Soon.
    TEACHER_REWARD_PER_CONFIRMATION_CENTS: int = 2   # base reward per confirmed rating
    TEACHER_VERIFY_CONFIRMATIONS: int = 1000          # confirmations to get verified + monetized
    TEACHER_REWARD_TIER_BONUS_CENTS: int = 1          # +per confirmation for each extra 1000
    TEACHER_REWARD_CURRENCY: str = "USD"

    @property
    def play_configured(self) -> bool:
        return bool(self.PLAY_SERVICE_ACCOUNT_FILE and self.PLAY_PACKAGE_NAME)

    @property
    def pro_product_ids(self) -> List[str]:
        return [p.strip() for p in (self.PRO_PRODUCT_IDS or "").split(",") if p.strip()]

    # WebRTC ICE / TURN (coturn REST ephemeral-credential mechanism)
    STUN_URL: str = "stun:stun.l.google.com:19302"
    TURN_HOST: str = ""  # e.g. turn.confrika.com — empty disables TURN relay
    TURN_PORT: int = 3478
    TURN_SECRET: str = ""  # shared static-auth-secret with coturn
    TURN_TTL_SECONDS: int = 86400

    @property
    def admin_emails(self) -> List[str]:
        return [e.strip().lower() for e in (self.ADMIN_EMAILS or "").split(",") if e.strip()]

    @property
    def is_production(self) -> bool:
        return self.APP_ENV.lower() == "production"

    @property
    def cors_origins(self) -> List[str]:
        raw = (self.ALLOWED_ORIGINS or "").strip()
        if raw == "*":
            # Wildcard is only honoured outside production.
            return ["*"] if not self.is_production else []
        return [o.strip() for o in raw.split(",") if o.strip()]

    @property
    def resolved_secret_key(self) -> str:
        if self.SECRET_KEY and self.SECRET_KEY.strip():
            return self.SECRET_KEY.strip()
        if self.is_production:
            raise RuntimeError(
                "SECRET_KEY environment variable must be set in production. "
                "Generate one with: python -c 'import secrets; print(secrets.token_urlsafe(48))'"
            )
        # Development fallback: ephemeral per-process key (tokens invalidate on restart).
        logger.warning(
            "SECRET_KEY not set — generating an ephemeral development key. "
            "Tokens will not survive a restart. Set SECRET_KEY for stable auth."
        )
        return _EPHEMERAL_DEV_KEY

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")


# Single ephemeral key per process (dev only).
_EPHEMERAL_DEV_KEY = secrets.token_urlsafe(48)

settings = Settings()
