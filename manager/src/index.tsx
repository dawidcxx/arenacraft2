import { createCliRenderer, TextAttributes } from "@opentui/core";
import { createRoot, useKeyboard } from "@opentui/react";
import { useState } from "react";
import { createRootCommands, type RootCommand } from "./commands/rootCommands";
import { createContainer } from "./container";

type Message = {
  source: "system" | "user" | "manager";
  text: string;
};

const container = createContainer();
const rootCommands = createRootCommands(container);

const initialMessages: Message[] = [
  {
    source: "system",
    text: "Arenacraft manager ready. Try /hello.",
  },
];

function App() {
  const [messages, setMessages] = useState<Message[]>(initialMessages);
  const [command, setCommand] = useState("");
  const [isRunningCommand, setIsRunningCommand] = useState(false);
  const commandHints = getCommandHints(command);

  useKeyboard((key) => {
    if (key.name !== "tab") {
      return;
    }

    const completedCommand = completeCommand(command);

    if (!completedCommand) {
      return;
    }

    key.preventDefault();
    setCommand(completedCommand);
  });

  async function runCommand(rawCommand: unknown) {
    if (typeof rawCommand !== "string") {
      return;
    }

    const trimmedCommand = rawCommand.trim();

    if (trimmedCommand.length === 0) {
      return;
    }

    if (isRunningCommand) {
      setMessages((currentMessages) => [
        ...currentMessages,
        { source: "system", text: "command already running" },
      ]);
      return;
    }

    const [commandName = "", ...commandArgs] = parseCommandLine(trimmedCommand);
    const rootCommand = rootCommands.find((registeredCommand) => registeredCommand.name === commandName);

    setMessages((currentMessages) => [
      ...currentMessages,
      { source: "user", text: trimmedCommand },
      ...(rootCommand?.runningText ? [{ source: "system" as const, text: rootCommand.runningText }] : []),
    ]);
    setCommand("");

    if (!rootCommand) {
      setMessages((currentMessages) => [
        ...currentMessages,
        { source: "system", text: `unknown command: ${trimmedCommand}` },
      ]);
      return;
    }

    setIsRunningCommand(true);
    try {
      const response = await rootCommand.run(commandArgs);
      setMessages((currentMessages) => [...currentMessages, { source: "manager", text: response }]);
    } catch (error) {
      setMessages((currentMessages) => [
        ...currentMessages,
        { source: "system", text: `${rootCommand.name.slice(1)} failed: ${getErrorMessage(error)}` },
      ]);
    } finally {
      setIsRunningCommand(false);
    }
  }

  return (
    <box flexDirection="column" flexGrow={1} padding={1} backgroundColor="#080b12">
      <box flexDirection="column" marginBottom={1}>
        <ascii-font font="tiny" text="arenacraft" color="#f5c542" />
        <text fg="#8aa0c8" attributes={TextAttributes.DIM}>
          wowcore server manager · repl ui
        </text>
      </box>

      <box
        flexDirection="column"
        flexGrow={1}
        borderStyle="rounded"
        borderColor="#26344f"
        padding={1}
        marginBottom={1}
      >
        {messages.map((message, index) => (
          <text key={`${message.source}-${index}`} fg={messageColor(message.source)}>
            {messagePrefix(message.source)} {message.text}
          </text>
        ))}
      </box>

      {commandHints.length > 0 ? (
        <box flexDirection="column" borderStyle="rounded" borderColor="#5f6f94" paddingLeft={1} paddingRight={1} marginBottom={1}>
          {commandHints.map((hint) => (
            <text fg="#f5c542">
              {hint.name} {hint.args}
            </text>
          ))}
          <text fg="#8aa0c8" attributes={TextAttributes.DIM}>
            Tab complete · Enter run
          </text>
        </box>
      ) : null}

      <box flexDirection="row" borderStyle="rounded" borderColor="#3d5a80" paddingLeft={1} paddingRight={1}>
        <text fg="#f5c542">$ </text>
        <input
          focused
          value={command}
          placeholder="run /hello"
          flexGrow={1}
          textColor="#e6edf3"
          cursorColor="#f5c542"
          backgroundColor="#080b12"
          focusedBackgroundColor="#080b12"
          onInput={setCommand}
          onSubmit={runCommand}
        />
      </box>
    </box>
  );
}

function messagePrefix(source: Message["source"]) {
  switch (source) {
    case "user":
      return ">";
    case "manager":
      return "<";
    case "system":
      return "*";
  }
}

function messageColor(source: Message["source"]) {
  switch (source) {
    case "user":
      return "#e6edf3";
    case "manager":
      return "#7ee787";
    case "system":
      return "#8aa0c8";
  }
}

function getCommandHints(command: string): RootCommand[] {
  const trimmedCommand = command.trimStart();

  if (!trimmedCommand.startsWith("/")) {
    return [];
  }

  const commandPrefix = trimmedCommand.split(/\s+/, 1)[0] ?? "";

  return rootCommands.filter((rootCommand) => rootCommand.name.startsWith(commandPrefix));
}

function completeCommand(command: string) {
  const leadingWhitespace = command.match(/^\s*/)?.[0] ?? "";
  const trimmedCommand = command.trimStart();
  const commandPrefix = trimmedCommand.split(/\s+/, 1)[0] ?? "";
  const commandHints = getCommandHints(command);
  const commandHint = commandHints[0];

  if (!commandHint || commandHint.name === commandPrefix) {
    return null;
  }

  const remainingInput = trimmedCommand.slice(commandPrefix.length).trimStart();
  const completedCommand = `${leadingWhitespace}${commandHint.name}`;

  if (remainingInput.length > 0) {
    return `${completedCommand} ${remainingInput}`;
  }

  return commandHint.args === "<void>" ? completedCommand : `${completedCommand} `;
}

function getErrorMessage(error: unknown) {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}

function parseCommandLine(commandLine: string) {
  return commandLine.split(/\s+/).filter((part) => part.length > 0);
}

const renderer = await createCliRenderer({ exitOnCtrlC: true });
createRoot(renderer).render(<App />);
