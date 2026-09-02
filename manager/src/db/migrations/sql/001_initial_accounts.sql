CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  username VARCHAR(16) NOT NULL,
  email VARCHAR(255) NULL,

  salt BYTEA NOT NULL,
  verifier BYTEA NOT NULL,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_login_at TIMESTAMPTZ NULL,

  last_ip INET NULL,

  CONSTRAINT accounts_username_unique UNIQUE (username),
  CONSTRAINT accounts_username_uppercase CHECK (username = UPPER(username)),
  CONSTRAINT accounts_username_len CHECK (char_length(username) BETWEEN 2 AND 16),
  CONSTRAINT accounts_salt_len CHECK (octet_length(salt) = 32),
  CONSTRAINT accounts_verifier_len CHECK (octet_length(verifier) = 32)
);
