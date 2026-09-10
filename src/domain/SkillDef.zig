//! Plain skill types. The catalog/grant lookups over the JSON rows live in
//! the game_data module.

/// One skill line we model, paired with the spell that represents it on the
/// wire (Language Common = skill 98 / spell 668). Skills and their spells
/// are two client-facing views of the same thing; see docs/spells.md.
pub const SkillDef = struct {
    /// SkillLine.dbc id.
    skill_id: u16,
    /// The spell the client needs to know for this skill to work.
    spell_id: u32,
};
