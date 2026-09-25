-- Earnova Production Database Schema for Supabase / PostgreSQL
-- Application: Earnova - "Complete. Earn. Grow."
-- Description: Complete tables, foreign keys, indexes, triggers, and Row Level Security (RLS)

-- 1. USERS & PROFILES
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    telegram_id BIGINT UNIQUE NOT NULL,
    username VARCHAR(64),
    first_name VARCHAR(128) NOT NULL,
    last_name VARCHAR(128),
    photo_url TEXT,
    language_code VARCHAR(10) DEFAULT 'en',
    channel_verified BOOLEAN DEFAULT FALSE,
    channel_verified_at TIMESTAMPTZ,
    referred_by_id UUID REFERENCES users(id) ON DELETE SET NULL,
    referral_code VARCHAR(32) UNIQUE NOT NULL,
    is_suspended BOOLEAN DEFAULT FALSE,
    suspension_reason TEXT,
    streak_days INT DEFAULT 1,
    last_active_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_telegram_id ON users(telegram_id);
CREATE INDEX IF NOT EXISTS idx_users_referral_code ON users(referral_code);

-- 2. WALLETS (Authoritative balance ledger anchor)
CREATE TABLE IF NOT EXISTS wallets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    available_balance_cents BIGINT NOT NULL DEFAULT 0, -- Stored in micro-cents (1 cent = 10000 micro-cents) or standard cents. In Earnova: stored in cents (e.g. 100 = $1.000, 1 = $0.010, fractional micro-units supported)
    pending_balance_cents BIGINT NOT NULL DEFAULT 0,
    total_earned_cents BIGINT NOT NULL DEFAULT 0,
    total_withdrawn_cents BIGINT NOT NULL DEFAULT 0,
    version INT NOT NULL DEFAULT 1, -- Optimistic concurrency control
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT chk_wallet_available_positive CHECK (available_balance_cents >= 0),
    CONSTRAINT chk_wallet_pending_positive CHECK (pending_balance_cents >= 0)
);

CREATE INDEX IF NOT EXISTS idx_wallets_user_id ON wallets(user_id);

-- 3. WALLET TRANSACTIONS (Strict Immutable Financial Ledger)
CREATE TYPE transaction_type AS ENUM (
    'TASK_REWARD',
    'MINING_REWARD',
    'REFERRAL_REWARD',
    'WITHDRAWAL',
    'WITHDRAWAL_REFUND',
    'CHALLENGE_REWARD',
    'PRIZE_POOL_WIN',
    'BONUS',
    'ADJUSTMENT'
);

CREATE TABLE IF NOT EXISTS wallet_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    wallet_id UUID NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount_cents BIGINT NOT NULL, -- Positive for credits, negative for debits
    balance_after_cents BIGINT NOT NULL,
    type transaction_type NOT NULL,
    reference_id TEXT, -- task_id, mining_session_id, withdrawal_id
    description TEXT NOT NULL,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wallet_tx_user_id ON wallet_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_created_at ON wallet_transactions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_ref ON wallet_transactions(reference_id);

-- 4. SPONSORED CAMPAIGNS & REVENUE MODEL
CREATE TABLE IF NOT EXISTS campaigns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    advertiser_name VARCHAR(128) NOT NULL,
    title VARCHAR(256) NOT NULL,
    description TEXT,
    advertiser_budget_cents BIGINT NOT NULL,
    user_reward_pool_cents BIGINT NOT NULL,
    platform_revenue_cents BIGINT NOT NULL,
    campaign_fee_cents BIGINT NOT NULL DEFAULT 0,
    remaining_budget_cents BIGINT NOT NULL,
    target_completions INT NOT NULL,
    current_completions INT NOT NULL DEFAULT 0,
    status VARCHAR(32) NOT NULL DEFAULT 'ACTIVE', -- ACTIVE, PAUSED, COMPLETED, EXPIRED
    start_date TIMESTAMPTZ DEFAULT NOW(),
    end_date TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. TASKS & REWARDS
CREATE TABLE IF NOT EXISTS tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID REFERENCES campaigns(id) ON DELETE SET NULL,
    title VARCHAR(256) NOT NULL,
    description TEXT NOT NULL,
    category VARCHAR(64) NOT NULL, -- 'telegram', 'twitter', 'social', 'community', 'featured', 'sponsored'
    platform VARCHAR(64) NOT NULL, -- 'Telegram', 'X', 'YouTube', 'Discord', 'Web'
    reward_cents BIGINT NOT NULL, -- e.g. 5 = $0.05
    estimated_time VARCHAR(32) NOT NULL DEFAULT '2 mins',
    action_url TEXT NOT NULL,
    verification_method VARCHAR(64) NOT NULL, -- 'BOT_API', 'DWELL_TIMER', 'MANUAL_REVIEW', 'TELEGRAM_CHANNEL'
    required_dwell_seconds INT DEFAULT 15,
    max_completions INT,
    current_completions INT DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tasks_category ON tasks(category);
CREATE INDEX IF NOT EXISTS idx_tasks_is_active ON tasks(is_active);

-- 6. TASK SUBMISSIONS & VERIFICATIONS
CREATE TABLE IF NOT EXISTS task_submissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    campaign_id UUID REFERENCES campaigns(id) ON DELETE SET NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'STARTED', -- 'STARTED', 'PENDING_VERIFICATION', 'APPROVED', 'REJECTED', 'COMPLETED'
    reward_cents BIGINT NOT NULL,
    verification_method VARCHAR(64) NOT NULL,
    proof_data JSONB DEFAULT '{}'::jsonb,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    submitted_at TIMESTAMPTZ,
    verified_at TIMESTAMPTZ,
    rejection_reason TEXT,
    CONSTRAINT uq_user_task UNIQUE (user_id, task_id)
);

CREATE INDEX IF NOT EXISTS idx_task_submissions_user ON task_submissions(user_id);
CREATE INDEX IF NOT EXISTS idx_task_submissions_task ON task_submissions(task_id);

-- 7. MINING / TIME-BASED ACCRUAL SESSIONS
CREATE TABLE IF NOT EXISTS mining_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ends_at TIMESTAMPTZ NOT NULL,
    rate_micro_cents_per_minute BIGINT NOT NULL DEFAULT 500, -- e.g. 500 micro-cents = $0.00005/min
    duration_minutes INT NOT NULL DEFAULT 480, -- 8 hours
    claimed_cents BIGINT DEFAULT 0,
    status VARCHAR(32) NOT NULL DEFAULT 'ACTIVE', -- 'ACTIVE', 'CLAIMED', 'EXPIRED'
    claimed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mining_user_status ON mining_sessions(user_id, status);

-- 8. REFERRALS & REWARDS
CREATE TABLE IF NOT EXISTS referrals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referrer_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    referred_id UUID UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    is_qualified BOOLEAN DEFAULT FALSE,
    qualification_reason TEXT,
    qualified_at TIMESTAMPTZ,
    reward_cents BIGINT DEFAULT 10, -- $0.10 upon qualification
    reward_paid BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_referrals_referrer ON referrals(referrer_id);

-- 9. WITHDRAWALS
CREATE TABLE IF NOT EXISTS withdrawals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount_cents BIGINT NOT NULL,
    fee_cents BIGINT NOT NULL DEFAULT 0,
    net_amount_cents BIGINT NOT NULL,
    method VARCHAR(64) NOT NULL, -- 'USDT_TRC20', 'TON', 'PAYEER', 'BINANCE_PAY'
    destination_address TEXT NOT NULL,
    status VARCHAR(32) NOT NULL DEFAULT 'PENDING', -- 'PENDING', 'PROCESSING', 'PAID', 'REJECTED'
    admin_note TEXT,
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_withdrawals_user ON withdrawals(user_id);
CREATE INDEX IF NOT EXISTS idx_withdrawals_status ON withdrawals(status);

-- 10. CHALLENGES & PROGRESS
CREATE TABLE IF NOT EXISTS challenges (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(256) NOT NULL,
    description TEXT NOT NULL,
    requirement_type VARCHAR(64) NOT NULL, -- 'TASKS_COMPLETED', 'REFERRALS_QUALIFIED', 'TIME_BLITZ'
    requirement_target INT NOT NULL,
    reward_cents BIGINT NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS challenge_progress (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    challenge_id UUID NOT NULL REFERENCES challenges(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    current_count INT NOT NULL DEFAULT 0,
    is_completed BOOLEAN DEFAULT FALSE,
    is_claimed BOOLEAN DEFAULT FALSE,
    claimed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_user_challenge UNIQUE (user_id, challenge_id)
);

-- 11. PRIZE POOLS
CREATE TABLE IF NOT EXISTS prize_pools (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(256) NOT NULL,
    prize_amount_cents BIGINT NOT NULL,
    winner_count INT NOT NULL DEFAULT 10,
    start_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    end_date TIMESTAMPTZ NOT NULL,
    eligibility_rule VARCHAR(128) NOT NULL DEFAULT 'COMPLETE_5_TASKS',
    status VARCHAR(32) NOT NULL DEFAULT 'ACTIVE', -- 'ACTIVE', 'DRAWING', 'DISTRIBUTED'
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS prize_pool_entries (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pool_id UUID NOT NULL REFERENCES prize_pools(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    is_winner BOOLEAN DEFAULT FALSE,
    prize_awarded_cents BIGINT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_pool_user UNIQUE (pool_id, user_id)
);

-- 12. ANNOUNCEMENTS
CREATE TABLE IF NOT EXISTS announcements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(256) NOT NULL,
    content TEXT NOT NULL,
    badge VARCHAR(64) DEFAULT 'Update',
    action_label VARCHAR(64),
    action_url TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 13. FRAUD FLAGS & AUDIT LOGS
CREATE TABLE IF NOT EXISTS fraud_flags (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    flag_type VARCHAR(64) NOT NULL, -- 'SELF_REFERRAL', 'SPEED_RUN', 'MULTIPLE_IPS', 'TAMPERED_HASH'
    severity VARCHAR(32) NOT NULL DEFAULT 'MEDIUM', -- 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'
    details JSONB DEFAULT '{}'::jsonb,
    is_resolved BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id TEXT NOT NULL, -- admin user or system
    action VARCHAR(128) NOT NULL,
    target_type VARCHAR(64) NOT NULL,
    target_id TEXT NOT NULL,
    payload JSONB DEFAULT '{}'::jsonb,
    ip_address VARCHAR(45),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ROW LEVEL SECURITY (RLS) POLICIES
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE mining_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE challenge_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE prize_pool_entries ENABLE ROW LEVEL SECURITY;

-- Read policies: Users can view their own data
CREATE POLICY "Users can view own profile" ON users FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can view own wallet" ON wallets FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can view own transactions" ON wallet_transactions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can view own submissions" ON task_submissions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can view own mining" ON mining_sessions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can view own withdrawals" ON withdrawals FOR SELECT USING (auth.uid() = user_id);

-- Tasks, Campaigns, Challenges, Prize Pools are publicly viewable
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public tasks viewable" ON tasks FOR SELECT USING (is_active = TRUE);

ALTER TABLE challenges ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public challenges viewable" ON challenges FOR SELECT USING (is_active = TRUE);

ALTER TABLE prize_pools ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public prize pools viewable" ON prize_pools FOR SELECT USING (TRUE);

ALTER TABLE announcements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public announcements viewable" ON announcements FOR SELECT USING (is_active = TRUE);
