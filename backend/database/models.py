import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column,
    String,
    Text,
    Boolean,
    Float,
    Integer,
    DateTime,
    ForeignKey,
    JSON,
    UniqueConstraint,
)
from sqlalchemy.orm import declarative_base, relationship

Base = declarative_base()


def _utcnow() -> datetime:
    """Naive UTC timestamp for the DateTime (timestamp-without-tz) columns.

    asyncpg (>=0.30) rejects tz-aware datetimes for naive columns, so we strip
    tzinfo while still computing the instant in UTC.
    """
    return datetime.now(timezone.utc).replace(tzinfo=None)


class User(Base):
    __tablename__ = "users"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    username = Column(String(40), unique=True, nullable=False, index=True)
    email = Column(String(255), unique=True, nullable=False, index=True)
    password_hash = Column(String(128), nullable=False)
    full_name = Column(String(120), nullable=False)
    country_code = Column(String(2), nullable=False, index=True)
    origin_region = Column(String(120), nullable=False)
    primary_dialect = Column(String(100), nullable=False)
    f0_baseline_hz = Column(Float, default=138.0)
    email_verified = Column(Boolean, default=False, nullable=False)
    # Base64 X25519 public key for end-to-end encrypted direct messages.
    public_key = Column(Text, nullable=True)
    # Privacy / reachability controls: 'everyone' | 'contacts' | 'nobody'.
    calls_privacy = Column(String(16), default="everyone", nullable=False)
    messages_privacy = Column(String(16), default="everyone", nullable=False)
    allow_images = Column(Boolean, default=True, nullable=False)
    # Profile picture (public media URL), or null for an initials avatar.
    avatar_url = Column(Text, nullable=True)
    # Admin / moderation.
    is_admin = Column(Boolean, default=False, nullable=False)
    is_banned = Column(Boolean, default=False, nullable=False)
    # Cloud voice-clone id for voice-preserving live call translation.
    voice_id = Column(String(80), nullable=True)
    # Monetization: 'free' | 'pro'. Pro removes ads and lifts the free-tier
    # usage/community limits. Entitlement is driven by a verified store purchase.
    subscription_tier = Column(String(16), default="free", nullable=False)
    subscription_platform = Column(String(16), nullable=True)  # 'google_play' | 'app_store'
    subscription_product_id = Column(String(120), nullable=True)
    subscription_token = Column(Text, nullable=True)  # store purchase/subscription token
    subscription_expires_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=_utcnow)
    updated_at = Column(
        DateTime,
        default=_utcnow,
        onupdate=_utcnow,
    )

    contacts = relationship("UserContact", back_populates="user", cascade="all, delete-orphan")
    sent_direct_messages = relationship(
        "DirectMessage", foreign_keys="DirectMessage.sender_id", back_populates="sender"
    )
    tonal_records = relationship(
        "TonalLearningRecord", back_populates="user", cascade="all, delete-orphan"
    )


class UserContact(Base):
    __tablename__ = "user_contacts"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    contact_username = Column(String(40), nullable=False, index=True)
    alias_name = Column(String(120), nullable=True)
    preferred_language = Column(String(100), nullable=True)
    created_at = Column(DateTime, default=_utcnow)

    user = relationship("User", back_populates="contacts")


class DirectMessage(Base):
    __tablename__ = "direct_messages"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    sender_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    recipient_username = Column(String(40), nullable=False, index=True)
    message_type = Column(String(20), default="text")  # 'text' | 'voicenote' | 'image' | 'sticker'
    # Plaintext fields (null for E2E-encrypted messages).
    original_text = Column(Text, nullable=True)
    translated_text = Column(Text, nullable=True)
    # Image/sticker media URL for non-encrypted messages (encrypted images carry
    # their URL inside the ciphertext payload instead).
    media_url = Column(Text, nullable=True)
    # Reply ("tag a message"): the id of the quoted message + a display snapshot.
    reply_to_id = Column(String(36), nullable=True)
    reply_snippet = Column(Text, nullable=True)
    reply_sender = Column(String(120), nullable=True)
    # End-to-end encryption: ciphertext (base64 nonce|ct|mac of a JSON payload
    # holding original + translated), and the sender's X25519 public key.
    is_encrypted = Column(Boolean, default=False, nullable=False)
    ciphertext = Column(Text, nullable=True)
    sender_pub = Column(Text, nullable=True)
    source_dialect = Column(String(100), nullable=False)
    target_dialect = Column(String(100), nullable=True)
    audio_url = Column(Text, nullable=True)
    audio_duration_seconds = Column(Float, nullable=True)
    is_read = Column(Boolean, default=False)
    created_at = Column(DateTime, default=_utcnow, index=True)

    sender = relationship("User", foreign_keys=[sender_id], back_populates="sent_direct_messages")


class GlobalSpacesMessage(Base):
    __tablename__ = "global_spaces_messages"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    sender_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    sender_name = Column(String(120), nullable=False)
    sender_username = Column(String(40), nullable=False)
    sender_location = Column(String(120), nullable=False)
    channel_category = Column(String(40), default="all")  # 'all', 'trade', 'culture'
    country_filter = Column(String(8), default="ALL")
    message_type = Column(String(20), default="text")
    original_text = Column(Text, nullable=False)
    translated_text = Column(Text, nullable=True)
    source_dialect = Column(String(100), nullable=False)
    audio_url = Column(Text, nullable=True)
    media_url = Column(Text, nullable=True)  # image/sticker URL for public posts
    reply_to_id = Column(String(36), nullable=True)
    reply_snippet = Column(Text, nullable=True)
    reply_sender = Column(String(120), nullable=True)
    duration_label = Column(String(10), nullable=True)
    sample_phrase = Column(String(120), nullable=True)
    sample_meaning = Column(String(120), nullable=True)
    created_at = Column(DateTime, default=_utcnow, index=True)


class CallSession(Base):
    __tablename__ = "call_sessions"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    caller_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    caller_username = Column(String(40), nullable=False)
    callee_username = Column(String(40), nullable=False, index=True)
    call_transport = Column(String(20), default="inapp")  # 'inapp' or 'telecom'
    status = Column(String(20), default="ringing")  # 'ringing', 'connected', 'ended', 'missed'
    started_at = Column(DateTime, default=_utcnow)
    connected_at = Column(DateTime, nullable=True)
    ended_at = Column(DateTime, nullable=True)
    duration_seconds = Column(Integer, default=0)


class Community(Base):
    """A joinable community (e.g. Business & Tech). Posts in Global Spaces are
    scoped to a community via its slug (GlobalSpacesMessage.channel_category)."""

    __tablename__ = "communities"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    slug = Column(String(40), unique=True, nullable=False, index=True)
    name = Column(String(80), nullable=False)
    description = Column(String(240), nullable=True)
    icon = Column(String(8), default="🌍")  # an emoji
    category = Column(String(40), default="general")
    is_default = Column(Boolean, default=False, nullable=False)  # everyone is a member
    created_by = Column(String(36), ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    created_at = Column(DateTime, default=_utcnow)


class CommunityMembership(Base):
    __tablename__ = "community_memberships"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    community_slug = Column(String(40), nullable=False, index=True)
    joined_at = Column(DateTime, default=_utcnow)


class DeviceToken(Base):
    """A device's push token (FCM) for message & call notifications."""

    __tablename__ = "device_tokens"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    token = Column(Text, nullable=False)
    platform = Column(String(16), default="android")  # 'android' | 'ios' | 'web'
    created_at = Column(DateTime, default=_utcnow)


class EmailVerification(Base):
    """A one-time email code for signup verification or password reset."""

    __tablename__ = "email_verifications"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    email = Column(String(255), nullable=False, index=True)
    code_hash = Column(String(128), nullable=False)
    purpose = Column(String(20), nullable=False)  # 'signup' | 'reset'
    attempts = Column(Integer, default=0)
    consumed = Column(Boolean, default=False)
    expires_at = Column(DateTime, nullable=False)
    created_at = Column(DateTime, default=_utcnow, index=True)


class NativeToneSample(Base):
    """A native speaker's recorded pitch contour for a target word.

    The platform aggregates these into a community (crowd-sourced) tone target
    so learners practise against real native speakers of the dialect.
    """

    __tablename__ = "native_tone_samples"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    word_id = Column(String(40), nullable=False, index=True)
    dialect = Column(String(100), nullable=False, index=True)
    contributor_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    semitone_contour = Column(JSON, nullable=False)
    mean_f0_hz = Column(Float, nullable=True)
    created_at = Column(DateTime, default=_utcnow, index=True)


class CommunityToneWord(Base):
    """A word taught by native speakers for the tonal coach. Lets any tonal
    language (e.g. Atyap/Tyap) be supported through real speaker contributions
    instead of fabricated tone data; the pitch target comes from NativeToneSample
    recordings aggregated by native_tone_service."""

    __tablename__ = "community_tone_words"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    word_id = Column(String(60), unique=True, nullable=False, index=True)
    language = Column(String(60), nullable=False, index=True)
    spelling = Column(String(80), nullable=False)
    meaning = Column(String(120), nullable=False)
    tone_pattern = Column(String(60), nullable=True)
    created_by = Column(String(36), ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    created_at = Column(DateTime, default=_utcnow)


class TonalLearningRecord(Base):
    __tablename__ = "tonal_learning_records"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    target_word = Column(String(80), nullable=False)
    diacritized_spelling = Column(String(80), nullable=False)
    meaning = Column(String(120), nullable=False)
    tone_pattern = Column(String(60), nullable=False)
    measured_f0_hz = Column(Float, nullable=False)
    semitone_contour = Column(JSON, nullable=False)
    match_score_pct = Column(Float, nullable=False)
    created_at = Column(DateTime, default=_utcnow)

    user = relationship("User", back_populates="tonal_records")


class TeacherProfile(Base):
    """A user's teaching profile for the 'learn from native speakers & earn' program."""

    __tablename__ = "teacher_profiles"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(
        String(36), ForeignKey("users.id", ondelete="CASCADE"),
        unique=True, nullable=False, index=True,
    )
    headline = Column(String(160), nullable=True)   # why learners should pick them
    bio = Column(Text, nullable=True)
    languages = Column(Text, nullable=True)          # comma-separated languages/dialects taught
    is_active = Column(Boolean, default=True, nullable=False)    # accepting learners
    is_verified = Column(Boolean, default=False, nullable=False)  # monetization/verified tag

    rating_count = Column(Integer, default=0, nullable=False)
    rating_sum = Column(Integer, default=0, nullable=False)       # sum of stars (avg = sum/count)
    confirmed_count = Column(Integer, default=0, nullable=False)  # "pronunciation is correct" confirmations
    reward_cents = Column(Integer, default=0, nullable=False)     # accumulated reward, minor units

    created_at = Column(DateTime, default=_utcnow)
    updated_at = Column(DateTime, default=_utcnow, onupdate=_utcnow)


class TeacherRating(Base):
    """One learner's rating/confirmation of a teacher (one per learner per teacher)."""

    __tablename__ = "teacher_ratings"
    __table_args__ = (
        UniqueConstraint("teacher_user_id", "rater_user_id", name="uq_teacher_rater"),
    )

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    teacher_user_id = Column(
        String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    rater_user_id = Column(
        String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    stars = Column(Integer, default=5, nullable=False)           # 1..5
    confirmed = Column(Boolean, default=True, nullable=False)    # pronunciation is correct
    comment = Column(Text, nullable=True)
    created_at = Column(DateTime, default=_utcnow)
    updated_at = Column(DateTime, default=_utcnow, onupdate=_utcnow)


class WithdrawalRequest(Base):
    """A teacher's request to cash out accumulated rewards (payouts: coming soon)."""

    __tablename__ = "withdrawal_requests"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    teacher_user_id = Column(
        String(36), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    amount_cents = Column(Integer, nullable=False)
    status = Column(String(20), default="coming_soon", nullable=False)  # coming_soon|pending|paid
    note = Column(Text, nullable=True)
    created_at = Column(DateTime, default=_utcnow)
