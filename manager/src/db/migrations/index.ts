import migration001 from "./sql/001_initial_schema.sql" with { type: "text" };

export const dbMigrations: readonly DbMigration[] = [migration("migration001", migration001)] as const;

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
