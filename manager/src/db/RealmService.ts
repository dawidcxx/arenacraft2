import { inject, injectable } from "@needle-di/core";
import { SQL } from "bun";

@injectable()
export class RealmService {
  constructor(private readonly sql: SQL = inject(SQL)) {}

  async createRealm(realmname: string): Promise<{ id: string; realmname: string }> {
    const trimmed = realmname.trim();

    if (trimmed.length === 0) {
      throw new Error("realmname is required");
    }

    if (trimmed.length > 32) {
      throw new Error("realmname must be 32 characters or fewer");
    }

    try {
      const rows = await this.sql<{ id: string; realmname: string }[]>`
        INSERT INTO realms (realmname)
        VALUES (${trimmed})
        RETURNING id::text, realmname
      `;
      const realm = rows[0];

      if (!realm) {
        throw new Error("realm insert did not return a row");
      }

      return realm;
    } catch (error) {
      if (isUniqueViolation(error)) {
        throw new Error(`realm already exists: ${trimmed}`);
      }

      throw error;
    }
  }
}

function isUniqueViolation(error: unknown) {
  return typeof error === "object" && error !== null && "code" in error && error.code === "ERR_POSTGRES_SERVER_ERROR" && "errno" in error && error.errno === "23505";
}
