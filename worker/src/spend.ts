import type { SpendReservation } from "./device-limiter";
import { RequestRejectedError } from "./http";
import type { RateLimitedRoute } from "./policy";

/** A reservation that can be corrected once, however many ways a request can end. */
export class DeviceSpend {
  private reservation: SpendReservation | null = null;
  private reservedMicroDollars = 0;

  constructor(
    private readonly deviceId: string,
    private readonly env: Env,
    private readonly executionContext: ExecutionContext,
  ) {}

  private get limiter() {
    return this.env.DEVICE_LIMITER.getByName(this.deviceId);
  }

  /** Refuses the whole request unless the device is within its rate and spend caps. */
  async reserveOrReject(route: RateLimitedRoute, microDollars: number): Promise<void> {
    const reservation = await this.limiter.reserveSpend(route, microDollars);
    if (!reservation.allowed) {
      throw new RequestRejectedError(reservation.denialCode!, {
        "retry-after": String(reservation.retryAfterSeconds),
      });
    }
    this.reservation = reservation;
    this.reservedMicroDollars = microDollars;
  }

  /** Reserves more for a connection that's already open. Returns false at the cap. */
  async reserveMore(microDollars: number): Promise<boolean> {
    const reservation = await this.limiter.reserveSpend(null, microDollars);
    if (reservation.allowed) this.reservedMicroDollars += microDollars;
    return reservation.allowed;
  }

  settle(actualMicroDollars: number): void {
    if (!this.reservation) return;
    const reservation = this.reservation;
    this.reservation = null;
    this.executionContext.waitUntil(
      this.limiter.settleSpend(reservation, this.reservedMicroDollars, actualMicroDollars).catch(() => {
        // The reservation stands, which overstates spend. That's the safe way to be wrong.
        console.log(JSON.stringify({ event: "settle_failed" }));
      }),
    );
  }

  refund(): void {
    this.settle(0);
  }
}
