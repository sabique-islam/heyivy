import { DurableObject } from "cloudflare:workers";
import {
  DAILY_SPEND_CAP_MICRO_DOLLARS,
  MONTHLY_SPEND_CAP_MICRO_DOLLARS,
  REQUESTS_PER_MINUTE,
  type RateLimitedRoute,
} from "./policy";

export interface SpendReservation {
  allowed: boolean;
  denialCode?: "rate_limited" | "spend_limit_reached";
  retryAfterSeconds?: number;
  /** Which periods were charged, so a correction lands on the same ones after midnight. */
  dayCounterKey: string;
  monthCounterKey: string;
}

const MILLISECONDS_PER_MINUTE = 60_000;
const MILLISECONDS_PER_DAY = 86_400_000;
const COUNTER_RETENTION_MS = 62 * MILLISECONDS_PER_DAY;

/**
 * One instance per device holds that device's rate and spend counters.
 *
 * Durable Objects run one call at a time, and nothing here awaits, so a check and its
 * charge can't be split by another request. That's what stops parallel requests from
 * racing past a cap. Spend is charged up front and corrected later, so a request that
 * never reports back stays charged, which errs towards stopping spend.
 */
export class DeviceLimiter extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS counters (
        counter_key TEXT PRIMARY KEY,
        counter_value INTEGER NOT NULL,
        expires_at_ms INTEGER NOT NULL
      )
    `);
  }

  private readCounter(counterKey: string): number {
    const rows = this.ctx.storage.sql
      .exec<{ counter_value: number }>("SELECT counter_value FROM counters WHERE counter_key = ?", counterKey)
      .toArray();
    return rows[0]?.counter_value ?? 0;
  }

  private addToCounter(counterKey: string, amount: number, expiresAtMs: number): void {
    this.ctx.storage.sql.exec(
      `INSERT INTO counters (counter_key, counter_value, expires_at_ms) VALUES (?1, ?2, ?3)
       ON CONFLICT (counter_key) DO UPDATE SET counter_value = MAX(0, counter_value + ?2)`,
      counterKey,
      amount,
      expiresAtMs,
    );
  }

  /**
   * Counts a request and reserves its spend, or refuses. Pass a null route to reserve
   * more spend for a connection that's already open, which isn't a new request.
   */
  reserveSpend(route: RateLimitedRoute | null, microDollars: number, nowMs: number = Date.now()): SpendReservation {
    this.ctx.storage.sql.exec("DELETE FROM counters WHERE expires_at_ms < ?", nowMs);

    const now = new Date(nowMs);
    const isoDate = now.toISOString();
    const dayCounterKey = `spend:day:${isoDate.slice(0, 10)}`;
    const monthCounterKey = `spend:month:${isoDate.slice(0, 7)}`;
    const periodKeys = { dayCounterKey, monthCounterKey };

    const currentMinute = Math.floor(nowMs / MILLISECONDS_PER_MINUTE);
    const rateCounterKey = `rate:${route}:${currentMinute}`;
    if (route !== null && this.readCounter(rateCounterKey) >= REQUESTS_PER_MINUTE[route]) {
      const nextMinuteMs = (currentMinute + 1) * MILLISECONDS_PER_MINUTE;
      return {
        allowed: false,
        denialCode: "rate_limited",
        retryAfterSeconds: Math.max(1, Math.ceil((nextMinuteMs - nowMs) / 1000)),
        ...periodKeys,
      };
    }

    const spendWouldPassDailyCap = this.readCounter(dayCounterKey) + microDollars > DAILY_SPEND_CAP_MICRO_DOLLARS;
    const spendWouldPassMonthlyCap =
      this.readCounter(monthCounterKey) + microDollars > MONTHLY_SPEND_CAP_MICRO_DOLLARS;
    if (spendWouldPassDailyCap || spendWouldPassMonthlyCap) {
      const nextDayMs = (Math.floor(nowMs / MILLISECONDS_PER_DAY) + 1) * MILLISECONDS_PER_DAY;
      const nextMonthMs = Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1);
      const resetsAtMs = spendWouldPassMonthlyCap ? nextMonthMs : nextDayMs;
      return {
        allowed: false,
        denialCode: "spend_limit_reached",
        retryAfterSeconds: Math.ceil((resetsAtMs - nowMs) / 1000),
        ...periodKeys,
      };
    }

    if (route !== null) {
      this.addToCounter(rateCounterKey, 1, nowMs + 2 * MILLISECONDS_PER_MINUTE);
    }
    this.addToCounter(dayCounterKey, microDollars, nowMs + COUNTER_RETENTION_MS);
    this.addToCounter(monthCounterKey, microDollars, nowMs + COUNTER_RETENTION_MS);
    return { allowed: true, ...periodKeys };
  }

  /** Replaces what was reserved with what the request really cost. */
  settleSpend(reservation: SpendReservation, reservedMicroDollars: number, actualMicroDollars: number): void {
    const correction = actualMicroDollars - reservedMicroDollars;
    const expiresAtMs = Date.now() + COUNTER_RETENTION_MS;
    this.addToCounter(reservation.dayCounterKey, correction, expiresAtMs);
    this.addToCounter(reservation.monthCounterKey, correction, expiresAtMs);
  }

  readSpend(nowMs: number = Date.now()): { todayMicroDollars: number } {
    const isoDate = new Date(nowMs).toISOString();
    return { todayMicroDollars: this.readCounter(`spend:day:${isoDate.slice(0, 10)}`) };
  }
}
