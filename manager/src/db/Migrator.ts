import { inject, injectable } from "@needle-di/core";
import { SQL } from "bun";
import { Logger } from "../lib/Logger";
import { dbMigrations } from "./migrations";

export type MigrationResult = {
  applied: boolean;
  count: number;
  elapsed: number;
};

@injectable()
export class Migrator {
  constructor(private readonly sql: SQL = inject(SQL)) {}

  async up(): Promise<MigrationResult> {
    const startedAt = Date.now();
    logger.info("Running migrations - Starting");

    await this.ensureMigrationsTable();

    const appliedCount = await this.sql.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(4703320732811)`;
      const applied = await this.getDbMigrations(tx);
      const appliedByNameSet = new Set(applied.map((it) => it.name));

      const selectedMigrations = dbMigrations.filter((it) => !appliedByNameSet.has(it.name));
      if (selectedMigrations.length === 0) return 0;
      logger.info(`Migrations to apply, count='${selectedMigrations.length}'`);

      const migrationString = selectedMigrations.map((it) => it.sql).join("\n;");

      await tx.unsafe(migrationString);

      const migrated = selectedMigrations.map((it) => ({ name: it.name, checksum: it.checksum }));
      await tx`INSERT INTO schema_migrations ${tx(migrated)}`;

      return selectedMigrations.length;
    });

    const elapsed = Date.now() - startedAt;
    if (appliedCount > 0) {
      logger.info("Migrations applied successfully", { elapsed, count: appliedCount });
    } else {
      logger.info("Migrations applied successfully (none applied)", { elapsed });
    }

    return { applied: appliedCount > 0, count: appliedCount, elapsed };
  }

  private async ensureMigrationsTable(): Promise<void> {
    await this.sql.unsafe(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        name TEXT PRIMARY KEY NOT NULL,
        checksum TEXT NOT NULL,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `);
  }

  private async getDbMigrations(tx: SQL): Promise<{ name: string; checksum: string }[]> {
    const rows = await tx<{ name: string; checksum: string }[]>`
      SELECT name, checksum
      FROM schema_migrations
      ORDER BY applied_at ASC, name ASC
    `;
    return rows;
  }
}

const logger = Logger.for(Migrator);
