CREATE TABLE realms (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  realmname VARCHAR(32) NOT NULL UNIQUE
);
