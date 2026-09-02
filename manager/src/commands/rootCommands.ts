import type { Container } from "@needle-di/core";
import { AccountService } from "../db/AccountService";
import { Migrator } from "../db/Migrator";
import { RealmService } from "../db/RealmService";
import { Logger } from "../lib/Logger";
import { serializeError } from "../lib/serializeError";

export type RootCommand = {
  name: string;
  args: string;
  description: string;
  runningText?: string;
  run: (args: string[]) => Promise<string> | string;
};

const logger = Logger.for("RootCommands");

export function createRootCommands(container: Container): RootCommand[] {
  const commands: RootCommand[] = [
    {
      name: "/adduser",
      args: "<username> <password>",
      description: "create account with SRP6 salt and verifier",
      runningText: "creating account...",
      run: async (args) => {
        const [username, password] = args;

        if (!username || !password) {
          throw new Error("usage: /adduser <username> <password>");
        }

        const account = await container.get(AccountService).addUser(username, password);
        return `account created, id=${account.id}, username=${account.username}`;
      },
    },
    {
      name: "/addrealm",
      args: "<realmname>",
      description: "create a realm entry",
      runningText: "creating realm...",
      run: async (args) => {
        const [realmname] = args;

        if (!realmname) {
          throw new Error("usage: /addrealm <realmname>");
        }

        const realm = await container.get(RealmService).createRealm(realmname);
        return `realm created, id=${realm.id}, realmname=${realm.realmname}`;
      },
    },
    {
      name: "/migrate",
      args: "<void>",
      description: "apply pending database migrations",
      runningText: "running migrations...",
      run: async () => {
        try {
          const result = await container.get(Migrator).up();

          if (result.applied) {
            return `migrations applied, count=${result.count}, elapsed=${result.elapsed}ms`;
          }

          return `migrations already up to date, elapsed=${result.elapsed}ms`;
        } catch (error) {
          logger.error("Failed to apply database migrations", { error: serializeError(error) });
          throw error;
        }
      },
    },
  ];

  commands.unshift({
    name: "/hello",
    args: "<void>",
    description: "list all available commands",
    run: () => {
        const maxLen = Math.max(...commands.map((cmd) => (cmd.name + " " + cmd.args).length));
        const prefix = "  ";
        return commands
          .map((cmd, i) => (i > 0 ? prefix : "") + (cmd.name + " " + cmd.args).padEnd(maxLen) + "  -  " + cmd.description)
          .join("\n");
      },
  });

  return commands;
}
