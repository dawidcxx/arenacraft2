import migration001 from "./sql/001_initial_accounts.sql" with { type: "text" };
import migration002 from "./sql/002_realms.sql" with { type: "text" };
import migration003 from "./sql/003_characters.sql" with { type: "text" };
import migration004 from "./sql/004_character_equipment.sql" with { type: "text" };
import migration005 from "./sql/005_integer_ids.sql" with { type: "text" };
import migration006 from "./sql/006_player_model_fields.sql" with { type: "text" };

export const dbMigrations: readonly DbMigration[] = [
  migration("migration001", migration001),
  migration("migration002", migration002),
  migration("migration003", migration003),
  migration("migration004", migration004),
  migration("migration005", migration005),
  migration("migration006", migration006),
] as const;

export type DbMigration = {
  name: string;
  sql: string;
  checksum: string;
};

function migration(name: string, sql: string): DbMigration {
  return {
    name,
    sql,
    checksum: Bun.hash(sql).toString(16),
  };
}
