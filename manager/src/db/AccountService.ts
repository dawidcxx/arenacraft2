import { inject, injectable } from "@needle-di/core";
import { SQL } from "bun";
import { makeRegistrationData } from "./srp6";

export type AddAccountResult = {
  id: string;
  username: string;
};

@injectable()
export class AccountService {
  constructor(private readonly sql: SQL = inject(SQL)) {}

  async addUser(username: string, password: string): Promise<AddAccountResult> {
    const normalizedUsername = validateUsername(username);
    const normalizedPassword = validatePassword(password);
    const registrationData = makeRegistrationData(normalizedUsername, normalizedPassword);

    try {
      const rows = await this.sql<{ id: string; username: string }[]>`
        INSERT INTO accounts (username, salt, verifier)
        VALUES (${normalizedUsername}, ${registrationData.salt}, ${registrationData.verifier})
        RETURNING id::text, username
      `;
      const account = rows[0];

      if (!account) {
        throw new Error("account insert did not return a row");
      }

      return account;
    } catch (error) {
      if (isUniqueViolation(error)) {
        throw new Error(`account already exists: ${normalizedUsername}`);
      }

      throw error;
    }
  }
}

function validateUsername(username: string) {
  const normalizedUsername = username.trim().toUpperCase();

  if (normalizedUsername.length < 2) {
    throw new Error("username must be at least 2 characters");
  }

  if (normalizedUsername.length > 16) {
    throw new Error("username must be 16 characters or fewer");
  }

  return normalizedUsername;
}

function validatePassword(password: string) {
  const normalizedPassword = password.trim().toUpperCase();

  if (normalizedPassword.length === 0) {
    throw new Error("password is required");
  }

  if (normalizedPassword.length > 16) {
    throw new Error("password must be 16 characters or fewer");
  }

  return normalizedPassword;
}

function isUniqueViolation(error: unknown) {
  return typeof error === "object" && error !== null && "code" in error && error.code === "ERR_POSTGRES_SERVER_ERROR" && "errno" in error && error.errno === "23505";
}
