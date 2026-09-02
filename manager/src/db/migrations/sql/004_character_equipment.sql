CREATE TABLE character_equipment (
  character_id UUID     NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
  slot         SMALLINT NOT NULL,
  item_entry   INTEGER  NOT NULL,
  enchant_id   INTEGER  NOT NULL DEFAULT 0,

  PRIMARY KEY (character_id, slot),

  CONSTRAINT character_equipment_slot_range CHECK (slot BETWEEN 0 AND 18),
  CONSTRAINT character_equipment_entry_positive CHECK (item_entry > 0),
  CONSTRAINT character_equipment_enchant_nonneg CHECK (enchant_id >= 0)
);

CREATE INDEX character_equipment_character_idx ON character_equipment (character_id);
