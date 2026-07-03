import { afterEach, describe, expect, mock, test } from "bun:test";

process.env.SKIP_ENV_VALIDATION = "1";
process.env.POSTHOG_PROJECT_KEY = "test-project-key";

const {
  normalizePostHogFlagsResponse,
  postHogFlagsBody,
  postHogFlagsUrl,
} = await import("../services/client-config/posthogFlags");
const { POST } = await import("../app/api/client-config/route");

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("client config", () => {
  test("normalizes detailed PostHog flag responses", () => {
    const config = normalizePostHogFlagsResponse({
      errorsWhileComputingFlags: false,
      requestId: "request-1",
      flags: {
        "pricing-page-copy": {
          enabled: true,
          variant: "checkout-a",
          metadata: { payload: "{\"cta\":\"Start\"}" },
        },
        "pricing-page-visible": {
          enabled: false,
          variant: null,
          metadata: { payload: null },
        },
        "pricing-page-disabled-variant": {
          enabled: false,
          variant: "checkout-b",
          metadata: { payload: "{\"cta\":\"Disabled\"}" },
        },
        "pricing-page-failed": {
          enabled: false,
          failed: true,
          metadata: { payload: "{\"cta\":\"Broken\"}" },
        },
      },
    });

    expect(config).toEqual({
      errorsWhileComputingFlags: false,
      requestId: "request-1",
      featureFlags: {
        "pricing-page-copy": "checkout-a",
        "pricing-page-visible": false,
        "pricing-page-disabled-variant": false,
      },
      featureFlagPayloads: {
        "pricing-page-copy": { cta: "Start" },
      },
    });
  });

  test("forwards route requests to PostHog flags from the server", async () => {
    const fetchCalls: Array<[RequestInfo | URL, RequestInit | undefined]> = [];
    const fetchMock = mock(async (...args: unknown[]) => {
      fetchCalls.push([args[0] as RequestInfo | URL, args[1] as RequestInit | undefined]);
      return new Response(
        JSON.stringify({
          errorsWhileComputingFlags: false,
          featureFlags: { "pricing-page-visible": true },
          featureFlagPayloads: { "pricing-page-visible": { plan: "team" } },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const response = await POST(new Request("https://cmux.test/api/client-config", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        distinctId: "browser-id",
        context: {
          groups: { organization: "org-1" },
          personProperties: { plan: "pro" },
          groupProperties: { organization: { tier: "team" } },
          anonDistinctId: "anon-id",
          deviceId: "device-id",
          timezone: "America/Los_Angeles",
          evaluationContexts: ["web"],
        },
      }),
    }));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      errorsWhileComputingFlags: false,
      featureFlags: { "pricing-page-visible": true },
      featureFlagPayloads: { "pricing-page-visible": { plan: "team" } },
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const fetchCall = fetchCalls[0];
    expect(fetchCall?.[0]).toBe(postHogFlagsUrl());
    const fetchInit = fetchCall?.[1] as RequestInit | undefined;
    expect(fetchInit).toMatchObject({
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: postHogFlagsBody("browser-id", {
        groups: { organization: "org-1" },
        personProperties: { plan: "pro" },
        groupProperties: { organization: { tier: "team" } },
        anonDistinctId: "anon-id",
        deviceId: "device-id",
        timezone: "America/Los_Angeles",
        evaluationContexts: ["web"],
      }),
      cache: "no-store",
    });
    expect(fetchInit?.signal).toBeInstanceOf(AbortSignal);
  });

  test("treats quota-limited or flagless upstream responses as unavailable", async () => {
    for (const upstreamBody of [{ quotaLimited: true }, { requestId: "request-without-flags" }]) {
      const fetchMock = mock(async () => new Response(
        JSON.stringify(upstreamBody),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ));
      globalThis.fetch = fetchMock as unknown as typeof fetch;

      const response = await POST(new Request("https://cmux.test/api/client-config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ distinctId: "browser-id" }),
      }));

      expect(response.status).toBe(502);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(await response.json()).toEqual({ error: "client_config_unavailable" });
    }
  });
});
