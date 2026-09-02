export class Logger {
  context: string;

  private constructor(context: string) {
    this.context = context;
  }

  static for(ctorOrName: NewableFunction | string): Logger {
    return new Logger(typeof ctorOrName === "string" ? ctorOrName : ctorOrName.name);
  }

  info(msg: string, meta: LoggerMetaObj = {}): void {
    this.writeLog("info", msg, meta);
  }

  warn(msg: string, meta: LoggerMetaObj = {}): void {
    this.writeLog("warn", msg, meta);
  }

  error(msg: string, meta: LoggerMetaObj = {}): void {
    this.writeLog("error", msg, meta);
  }

  private writeLog(level: string, message: string, meta: LoggerMetaObj) {
    const line = JSON.stringify({
      level,
      message,
      ts: new Date().toISOString(),
      meta,
      context: this.context,
    });
    console.log(line);
  }
}

export type LoggerMetaObj = Record<string, unknown> & {
  resourceId?: string | number | null;
};
