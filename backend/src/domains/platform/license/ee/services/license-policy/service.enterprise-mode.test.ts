import { verifyOfflineLicense } from "@app/lib/crypto";

import { InstanceType } from "../../../ce/models/instance-entitlements";
import { SELF_HOSTED_LICENSE_ORG_ID, TEntitlementsResponse } from "../../../ce/services/helpers/license-server-types";
import { LicenseEeModule, TLicenseEeDeps } from "../../module";
import { TLicenseServerEntitlements } from "../dependencies";
import { getLicenseKeyConfig } from "./license-key";
import { LicensePolicyService } from "./service";

vi.mock("@app/lib/crypto", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@app/lib/crypto")>()),
  verifyOfflineLicense: vi.fn()
}));

vi.mock("@app/lib/logger", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@app/lib/logger")>()),
  logger: { info: vi.fn(), error: vi.fn(), warn: vi.fn(), debug: vi.fn() }
}));

const offlineKey = (terminatesAt: string | null = null) =>
  Buffer.from(
    JSON.stringify({
      license: { licenseId: "test-license", terminatesAt, features: { rbac: true } },
      signature: "test-signature"
    })
  ).toString("base64");

const makePolicy = (licenseKey = "", isCloud = false) => {
  const getEntitlements = vi.fn<TLicenseServerEntitlements["getEntitlements"]>().mockResolvedValue(null);
  const policy = new LicensePolicyService(
    isCloud,
    getLicenseKeyConfig({ LICENSE_KEY: licenseKey }),
    { getEntitlements },
    true
  );
  return { policy, getEntitlements };
};

describe("LicensePolicyService Enterprise Mode", () => {
  beforeEach(() => {
    vi.mocked(verifyOfflineLicense).mockResolvedValue(true);
  });

  test("enables Enterprise Mode in the unlicensed self-hosted fall-through", async () => {
    const { policy } = makePolicy();
    const instance = await policy.resolveInstanceEntitlements();

    expect(instance.toJSON()).toMatchObject({
      instanceType: InstanceType.OnPrem,
      licenseId: null,
      features: { slug: "enterprise", maxCas: null, agentVaultManagedStorage: true }
    });
  });

  test("preserves the cloud early return", async () => {
    const { policy, getEntitlements } = makePolicy("test-online-key", true);
    const instance = await policy.resolveInstanceEntitlements();

    expect(instance.instanceType).toBe(InstanceType.Cloud);
    expect(instance.toJSON().features.slug).toBeNull();
    expect(getEntitlements).not.toHaveBeenCalled();
  });

  test("preserves the online license's projected entitlements", async () => {
    const { policy, getEntitlements } = makePolicy("test-online-key");
    getEntitlements.mockResolvedValue({ slug: "advanced", features: {}, products: [] } as TEntitlementsResponse);
    const instance = await policy.resolveInstanceEntitlements();

    expect(instance.instanceType).toBe(InstanceType.EnterpriseOnPrem);
    expect(instance.toJSON().features.slug).toBe("advanced");
    expect(getEntitlements).toHaveBeenCalledWith({ id: SELF_HOSTED_LICENSE_ORG_ID });
  });

  test("preserves the verified offline license's projected entitlements", async () => {
    const { policy, getEntitlements } = makePolicy(offlineKey());
    const instance = await policy.resolveInstanceEntitlements();

    expect(instance.toJSON()).toMatchObject({
      instanceType: InstanceType.EnterpriseOnPremOffline,
      licenseId: "test-license",
      features: { slug: "enterprise", isOffline: true, rbac: true, agentVaultManagedStorage: false }
    });
    expect(getEntitlements).not.toHaveBeenCalled();
  });

  test("falls back to community when offline signature verification fails", async () => {
    vi.mocked(verifyOfflineLicense).mockResolvedValue(false);
    const instance = await makePolicy(offlineKey()).policy.resolveInstanceEntitlements();

    expect(instance.instanceType).toBe(InstanceType.OnPrem);
    expect(instance.toJSON().features.slug).toBeNull();
  });

  test("falls back to community when the offline license has terminated", async () => {
    const key = offlineKey("2025-01-02T00:00:00.000Z");
    const instance = await makePolicy(key).policy.resolveInstanceEntitlements();

    expect(instance.instanceType).toBe(InstanceType.OnPrem);
    expect(instance.toJSON().features.slug).toBeNull();
  });

  test("falls back to community when reading the online license throws", async () => {
    const { policy, getEntitlements } = makePolicy("test-online-key");
    getEntitlements.mockRejectedValue(new Error("License Server unavailable"));
    const instance = await policy.resolveInstanceEntitlements();

    expect(instance.instanceType).toBe(InstanceType.OnPrem);
    expect(instance.toJSON().features.slug).toBeNull();
  });

  test.each<[string, Partial<TLicenseEeDeps["envConfig"]>, string | null]>([
    ["no key", {}, "enterprise"],
    ["LICENSE_KEY", { LICENSE_KEY: "test-online-key" }, null],
    ["LICENSE_KEY_OFFLINE", { LICENSE_KEY_OFFLINE: "not-an-offline-key" }, null]
  ])("wires the mode for %s", async (_label, keys, slug) => {
    const module = new LicenseEeModule({ envConfig: { LICENSE_KEY: "", isCloud: false, ...keys } });
    vi.spyOn(module.licenseServerClient, "getEntitlements").mockResolvedValue(null);
    const instance = await module.licensePolicyService.resolveInstanceEntitlements();

    expect(instance.instanceType).toBe(InstanceType.OnPrem);
    expect(instance.toJSON().features.slug).toBe(slug);
  });
});
