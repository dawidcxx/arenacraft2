import { Container } from "@needle-di/core";
import { SQL } from "bun";

export function createContainer(): Container {
  const container = new Container();

  container.bind({
    provide: SQL,
    useFactory: () => new SQL(getDatabaseUrl()),
  });

  return container;
}

function getDatabaseUrl() {
  const databaseUrl = process.env.DATABASE_URL;

  if (!databaseUrl) {
    throw new Error("DATABASE_URL is required");
  }

  return databaseUrl;
}
